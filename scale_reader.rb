require 'socket'
require 'io/wait'

# Reads a Gram Xtrem scale continuously in a background thread and keeps
# the latest readings in memory, so HTTP requests answer immediately
# instead of opening a measurement window on every request.
#
# Frames observed on a Gram Xtrem F (RS-232, 9600 8N1, ~10 frames/s):
#   STX "0100r01071AW   1.025kgT   0.000kgS01062" ETX CRLF   weight (gross kgT)
#   STX "0100r010002487C" ETX CRLF                           no weight: below zero
#                                                            or error state
#   STX "0100e101101054" ETX CRLF                            ack of a command
class ScaleReader
  STX = "\u0002".freeze
  ETX = "\u0003".freeze
  CMD_STREAM_ON = "#{STX}00FFE10110000#{ETX}\r\n".freeze
  CMD_STREAM_OFF = "#{STX}00FFE10100000#{ETX}\r\n".freeze
  CMD_ZERO = "#{STX}00FFE01050000#{ETX}\r\n".freeze

  WEIGHT_PATTERN = /([-+])?\s*(\d+(?:[.,]\d+)?)\s*kgT/.freeze
  NO_WEIGHT_PATTERN = /r010002/.freeze

  MESSAGES = {
    no_data: 'Váha neposílá data. Zkontrolujte, že je zapnutá a připojená kabelem.',
    no_weight: 'Váha je pod nulou nebo v chybě a neposílá hmotnost. ' \
               'Sundejte vše z váhy a odpojte ji na 10 s ze zásuvky.',
    unstable: 'Váha není ustálená.',
    negative: 'Váha ukazuje %<grams>d g. Sundejte vše z váhy a vynulujte ji.'
  }.freeze

  Reading = Struct.new(:grams, :at)

  def initialize(io_factory:, window: 5, tolerance: 5, max_age: 1.5, logger: $stdout)
    @io_factory = io_factory
    @window = window
    @tolerance = tolerance
    @max_age = max_age
    @logger = logger
    @readings = []
    @no_weight_at = nil
    @mutex = Mutex.new
    @io = nil
    @lines_read = 0
  end

  # grams (Integer), :no_weight, or nil for frames we do not understand
  def self.parse(line)
    return nil unless line
    return :no_weight if line.match?(NO_WEIGHT_PATTERN) && !line.include?('kg')

    match = line.match(WEIGHT_PATTERN)
    return nil unless match

    kg = match[2].tr(',', '.').to_f
    kg = -kg if match[1] == '-'
    (kg * 1000).round
  end

  def start
    @thread = Thread.new { run_loop }
    self
  end

  def stop
    @stopping = true
    safe_write(CMD_STREAM_OFF)
    @io&.close
  rescue StandardError
    nil
  end

  # Waits up to `timeout` seconds for a fresh, stable weight.
  # Returns { status: :ok, grams: } or { status: :error, reason:, message: }.
  def weight(timeout: 3.0)
    deadline = monotonic + timeout
    loop do
      state = current_state
      return state if state[:status] == :ok || monotonic >= deadline

      sleep 0.05
    end
  end

  # Current state without waiting (for live display).
  def current_state
    readings, no_weight_at = @mutex.synchronize { [@readings.last(@window), @no_weight_at] }
    last_at = [readings.last&.at, no_weight_at].compact.max

    return error(:no_data) if last_at.nil? || monotonic - last_at > @max_age
    return error(:no_weight) if no_weight_at && no_weight_at == last_at

    grams = stable_median(readings)
    return error(:unstable) unless grams

    grams = 0 if grams.negative? && grams >= -@tolerance
    return error(:negative, grams: grams) if grams.negative?

    { status: :ok, grams: grams }
  end

  # Asks the scale to zero itself and reports whether it then reads ~0.
  # The scale accepts the zero command even with a load on it (440 g on
  # 2026-11-11), so refuse here unless it reads at most MAX_ZERO_GRAMS or
  # a negative drift. When the drift is outside the scale's zero range, only
  # a power cycle with an empty platform resets the zero.
  MAX_ZERO_GRAMS = 20

  def zero!
    before = weight(timeout: 2.0)
    if before[:status] == :ok && before[:grams] > MAX_ZERO_GRAMS
      return { status: :error, reason: :not_empty,
               message: "Váha ukazuje #{before[:grams]} g. Nulovat jde jen prázdnou váhu." }
    end
    return before if before[:status] == :error && before[:reason] != :negative

    safe_write(CMD_ZERO)
    sleep 1.5
    state = weight(timeout: 2.0)
    return { status: :ok, grams: 0 } if state[:status] == :ok && state[:grams].zero?
    return state if state[:status] == :error

    { status: :error, reason: :not_empty,
      message: "Váha po vynulování ukazuje #{state[:grams]} g. Nulovat jde jen prázdnou váhu." }
  end

  def status
    readings, no_weight_at = @mutex.synchronize { [@readings.dup, @no_weight_at] }
    current_state.merge(
      raw_window: readings.last(@window).map(&:grams),
      last_reading_age_s: readings.last && (monotonic - readings.last.at).round(2),
      no_weight_age_s: no_weight_at && (monotonic - no_weight_at).round(2),
      last_line: @last_line,
      lines_read: @lines_read,
      last_error: @last_error
    )
  end

  private

  def error(reason, **values)
    { status: :error, reason: reason, message: format(MESSAGES.fetch(reason), **values) }
  end

  # Median of the readings, nil if there are not enough or they differ too much.
  def stable_median(readings)
    return nil if readings.size < @window
    return nil if monotonic - readings.first.at > @max_age * 2

    values = readings.map(&:grams).sort
    return nil if values.last - values.first > @tolerance * 2

    values[values.size / 2]
  end

  def run_loop
    until @stopping
      begin
        @io = @io_factory.call
        @last_error = nil
        safe_write(CMD_STREAM_ON)
        last_data = monotonic
        until @stopping
          line = @io.gets("\r\n")
          if line.nil?
            # read timeout: wake the stream up again if it went quiet
            if monotonic - last_data > 3
              safe_write(CMD_STREAM_ON)
              last_data = monotonic
            end
            next
          end

          @lines_read += 1
          @last_line = line.delete("\u0002\u0003").strip
          parsed = self.class.parse(line)
          next unless parsed

          last_data = monotonic
          record(parsed)
        end
      rescue StandardError => e
        @last_error = "#{e.class}: #{e.message}"
        log("reader error: #{@last_error}, reconnecting in 2 s")
        begin
          @io&.close
        rescue StandardError
          nil
        end
        @io = nil
        sleep 2
      end
    end
  end

  def record(parsed)
    @mutex.synchronize do
      if parsed == :no_weight
        @no_weight_at = monotonic
        @readings.clear
      else
        @no_weight_at = nil
        @readings << Reading.new(parsed, monotonic)
        @readings.shift while @readings.size > 50
      end
    end
  end

  def safe_write(data)
    @io&.write(data)
  rescue StandardError => e
    @last_error = "write: #{e.class}: #{e.message}"
  end

  def log(message)
    @logger&.puts("[scale] #{message}")
    @logger&.flush
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end

# Simulated scale for local development (SCALE_PORT=test).
class FakeScaleIO
  def initialize(grams: 1235)
    @grams = grams
  end

  def write(data) = data.bytesize

  def gets(_sep = nil)
    sleep 0.1
    format("\u00020100r01071AW %7.3fkgT   0.000kgS01062\u0003\r\n", @grams / 1000.0)
  end

  def close; end
end

# Gram Wi-Fi/Ethernet modules usually expose the same protocol over TCP.
class TcpScaleIO
  def initialize(host, port, read_timeout: 1.0)
    @socket = Socket.tcp(host, port, connect_timeout: 3)
    @read_timeout = read_timeout
    @buffer = +''
  end

  def write(data) = @socket.write(data)

  def gets(sep = "\r\n")
    until (idx = @buffer.index(sep))
      return nil unless @socket.wait_readable(@read_timeout)

      chunk = @socket.read_nonblock(4096, exception: false)
      raise EOFError, 'scale closed connection' if chunk.nil?
      next if chunk == :wait_readable

      @buffer << chunk
    end
    @buffer.slice!(0, idx + sep.size)
  end

  def close = @socket.close
end
