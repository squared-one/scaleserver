require 'minitest/autorun'
require_relative 'scale_reader'

class ScriptedIO
  attr_reader :writes

  def initialize(lines, repeat_last: false)
    @lines = lines.dup
    @repeat_last = repeat_last
    @writes = []
  end

  def write(data)
    @writes << data
  end

  def gets(_sep = nil)
    sleep 0.01
    line = @lines.size > 1 || !@repeat_last ? @lines.shift : @lines.first
    line || (sleep(0.05) && nil)
  end

  def close; end
end

class ScaleReaderTest < Minitest::Test
  NO_WEIGHT = "\u00020100r010002487C\u0003\r\n".freeze

  def frame(kg)
    format("\u00020100r01071AW %7.3fkgT   0.000kgS01062\u0003\r\n", kg)
  end

  def reader_for(lines, repeat_last: false)
    io = ScriptedIO.new(lines, repeat_last: repeat_last)
    reader = ScaleReader.new(io_factory: -> { io }, logger: nil).start
    [reader, io]
  end

  # Real frames captured from the scale on 2026-11-11
  def test_parse_real_frames
    assert_equal 80, ScaleReader.parse("\u00020100r01071AW   0.080kgT   0.000kgS0106C\u0003\r\n")
    assert_equal 4565, ScaleReader.parse("\u00020100r01071AW   4.565kgT   0.000kgS01066\u0003")
    assert_equal(-85, ScaleReader.parse("\u00020100r01071AW  -0.085kgT   0.000kgS01064\u0003"))
    assert_equal 0, ScaleReader.parse("\u00020100r01071AW   0.000kgT   0.000kgS01561\u0003")
    assert_equal :no_weight, ScaleReader.parse(NO_WEIGHT)
    assert_nil ScaleReader.parse("\u00020100e101101054\u0003")
    assert_nil ScaleReader.parse(nil)
  end

  def test_returns_median_of_stable_window
    reader, io = reader_for([frame(0.500), frame(0.505), frame(0.500), frame(0.500), frame(0.505)])
    assert_equal({ status: :ok, grams: 500 }, reader.weight)
    assert_includes io.writes, ScaleReader::CMD_STREAM_ON
  end

  def test_small_negative_is_zero
    reader, = reader_for([frame(-0.005)] * 5)
    assert_equal({ status: :ok, grams: 0 }, reader.weight)
  end

  def test_large_negative_is_error
    reader, = reader_for([frame(-0.085)] * 5)
    state = reader.weight(timeout: 0.5)
    assert_equal :negative, state[:reason]
    assert_match(/-85 g/, state[:message])
  end

  def test_no_weight_frame_is_explained
    reader, = reader_for([frame(0.1)] * 5 + [NO_WEIGHT], repeat_last: true)
    state = reader.weight(timeout: 0.5)
    assert_equal :no_weight, state[:reason]
    assert_match(/ze zásuvky/, state[:message])
  end

  def test_no_data_is_error
    reader, = reader_for([])
    assert_equal :no_data, reader.weight(timeout: 0.3)[:reason]
  end

  def test_unstable_is_error
    reader, = reader_for([frame(0.1), frame(0.3), frame(0.2), frame(0.5), frame(0.05)])
    assert_equal :unstable, reader.weight(timeout: 0.3)[:reason]
  end

  def test_zero_sends_command_and_confirms
    reader, io = reader_for([frame(0)], repeat_last: true)
    sleep 0.1
    assert_equal({ status: :ok, grams: 0 }, reader.zero!)
    assert_includes io.writes, ScaleReader::CMD_ZERO
  end

  def test_zero_with_load_is_refused_without_sending_the_command
    reader, io = reader_for([frame(0.44)], repeat_last: true)
    assert_equal :not_empty, reader.zero![:reason]
    refute_includes io.writes, ScaleReader::CMD_ZERO
  end

  def test_zero_fixes_negative_drift
    reader, io = reader_for([frame(-0.085)], repeat_last: true)
    sleep 0.1
    reader.zero!
    assert_includes io.writes, ScaleReader::CMD_ZERO
  end

  def test_reconnects_after_io_error
    calls = 0
    factory = lambda do
      calls += 1
      raise Errno::ENOENT, '/dev/ttyUSB0' if calls == 1

      ScriptedIO.new([frame(0.2)] * 10)
    end
    reader = ScaleReader.new(io_factory: factory, logger: nil).start
    assert_equal({ status: :ok, grams: 200 }, reader.weight(timeout: 4))
  end
end
