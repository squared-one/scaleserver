require 'json'
require 'socket'

# Reads a Gram Xtrem scale continuously in a background thread and keeps
# the latest readings in memory, so HTTP requests answer immediately
# instead of opening a measurement window on every request.
class ScaleReader
  STX = "\u0002".freeze
  ETX = "\u0003".freeze
  CMD_STREAM_ON = "#{STX}00FFE10110000#{ETX}\r\n".freeze
  CMD_STREAM_OFF = "#{STX}00FFE10100000#{ETX}\r\n".freeze
  CMD_ZERO = "#{STX}00FFE01050000#{ETX}\r\n".freeze

  # "  0.123 kgT", "-0.004kgT", "- 0.004 kg" → grams (Integer) or nil
  WEIGHT_PATTERN = /([-+])?\s*(\d+(?:[.,]\d+)?)\s*kg/i.freeze

  Reading = Struct.new(:grams, :at)

  attr_reader :last_line, :last_error, :lines_read

  def initialize(io_factory:, offset_file: nil, window: 5, tolerance: 2,
                 max_age: 1.5, logger: $stdout)
    @io_factory = io_factory
    @offset_file = offset_file
    @window = window
    @tolerance = tolerance
    @max_age = max_age
    @logger = logger
    @readings = []
    @mutex = Mutex.new
    @io = nil
    @lines_read = 0
    @offset = load_offset
  end

  def self.parse_grams(line)
    return nil unless line

    match = line.match(WEIGHT_PATTERN)
    return nil unless match

    kg = match[2].tr(',', '.').to_f
    kg = -kg if match[1] == '-'
    (kg * 1000).round
  end

  def start
    @thread = Thread.new { run_loop }
    @thread.abort_on_exception = false
    self
  end

  def stop
    @stopping = true
    safe_write(CMD_STREAM_OFF)
    @io&.close
  rescue StandardError
    nil
  end

  # Returns [:ok, grams] or [:error, message].
  # Waits up to `timeout` seconds for a fresh, stable window of readings.
  def weight(timeout: 3.0)
    deadline = monotonic + timeout
    loop do
      state = current_state
      return [:ok, state[:grams]] if state[:status] == :ok
      return [:error, state[:message]] if monotonic >= deadline

      sleep 0.05
    end
  end

  # Hardware zero + software zero (offset), so a drifted zero that the
  # scale refuses to reset is still compensated.
  def zero!(max_offset: 500)
    safe_write(CMD_ZERO)
    sleep 1.0
    raw = stable_raw_median
    return [:error, 'Váha není ustálená nebo neposílá data, zkuste to znovu.'] unless raw

    if raw.abs > max_offset
      return [:error, "Váha ukazuje #{raw} g. Nulovat jde jen prázdnou váhu (do #{max_offset} g)."]
    end

    @mutex.synchronize { @offset = raw }
    save_offset(raw)
    [:ok, raw]
  end

  def status
    state = current_state
    readings = @mutex.synchronize { @readings.dup }
    {
      status: state[:status],
      grams: state[:grams],
      message: state[:message],
      offset_grams: @offset,
      raw_window: readings.map(&:grams),
      last_reading_age_s: readings.last && (monotonic - readings.last.at).round(2),
      last_line: @last_line,
      lines_read: @lines_read,
      last_error: @last_error
    }
  end

  private

  def current_state
    raw = stable_raw_median
    readings = @mutex.synchronize { @readings.dup }

    if readings.empty? || monotonic - readings.last.at > @max_age
      return { status: :error, message: 'Váha neposílá data. Zkontrolujte, že je zapnutá a připojená.' }
    end
    return { status: :error, message: 'Váha není ustálená.' } unless raw

    grams = raw - @offset
    grams = 0 if grams.negative? && grams >= -@tolerance

    if grams.negative?
      return { status: :error, message: "Váha ukazuje #{grams} g. Sundejte vše z váhy a vynulujte ji (/zero)." }
    end

    { status: :ok, grams: grams }
  end

  # Median of the last `window` fresh readings, nil if they are not stable.
  def stable_raw_median
    readings = @mutex.synchronize { @readings.last(@window) }
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
          @last_line = line.strip
          grams = self.class.parse_grams(line)
          next unless grams

          last_data = monotonic
          push(grams)
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

  def push(grams)
    @mutex.synchronize do
      @readings << Reading.new(grams, monotonic)
      @readings.shift while @readings.size > 50
    end
  end

  def safe_write(data)
    @io&.write(data)
  rescue StandardError => e
    @last_error = "write: #{e.class}: #{e.message}"
  end

  def load_offset
    return 0 unless @offset_file && File.exist?(@offset_file)

    JSON.parse(File.read(@offset_file)).fetch('offset_grams', 0).to_i
  rescue StandardError
    0
  end

  def save_offset(value)
    return unless @offset_file

    File.write(@offset_file, JSON.generate(offset_grams: value, saved_at: Time.now.to_s))
  rescue StandardError => e
    log("cannot save offset: #{e.message}")
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
  def initialize(grams: 1234)
    @grams = grams
  end

  def write(data) = data.bytesize

  def gets(_sep = nil)
    sleep 0.1
    kg = (@grams + rand(-1..1)) / 1000.0
    format("ST,GS  %.3f kgT\r\n", kg)
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
