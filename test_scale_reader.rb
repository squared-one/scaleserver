require 'minitest/autorun'
require 'tmpdir'
require_relative 'scale_reader'

class ScriptedIO
  attr_reader :writes

  def initialize(lines)
    @lines = lines.dup
    @writes = []
  end

  def write(data)
    @writes << data
  end

  def gets(_sep = nil)
    sleep 0.01
    @lines.shift || (sleep(0.05) && nil)
  end

  def close; end
end

class ScaleReaderTest < Minitest::Test
  def reader_for(lines, **opts)
    io = ScriptedIO.new(lines)
    reader = ScaleReader.new(io_factory: -> { io }, logger: nil, **opts).start
    [reader, io]
  end

  def test_parse_grams
    assert_equal 123, ScaleReader.parse_grams("ST,GS  0.123 kgT\r\n")
    assert_equal(-4, ScaleReader.parse_grams("-0.004kgT\r\n"))
    assert_equal(-4, ScaleReader.parse_grams("ST,GS - 0.004 kgT\r\n"))
    assert_equal 1500, ScaleReader.parse_grams('1,500 kg')
    assert_nil ScaleReader.parse_grams('garbage')
    assert_nil ScaleReader.parse_grams(nil)
  end

  def test_returns_median_of_stable_window
    reader, io = reader_for(['0.500 kgT', '0.501 kgT', '0.499 kgT', '0.500 kgT', '0.501 kgT'])
    assert_equal [:ok, 500], reader.weight
    assert_includes io.writes, ScaleReader::CMD_STREAM_ON
  end

  def test_small_negative_is_zero
    reader, = reader_for(['-0.001 kgT'] * 5)
    assert_equal [:ok, 0], reader.weight
  end

  def test_large_negative_is_error_not_crash
    reader, = reader_for(['-0.050 kgT'] * 5)
    status, message = reader.weight(timeout: 0.5)
    assert_equal :error, status
    assert_match(/-50 g/, message)
  end

  def test_no_data_is_error_not_crash
    reader, = reader_for([])
    status, message = reader.weight(timeout: 0.3)
    assert_equal :error, status
    assert_match(/neposílá data/, message)
  end

  def test_unstable_is_error
    reader, = reader_for(['0.100 kgT', '0.300 kgT', '0.200 kgT', '0.500 kgT', '0.050 kgT'])
    status, message = reader.weight(timeout: 0.3)
    assert_equal :error, status
    assert_match(/ustálená/, message)
  end

  def test_software_zero_compensates_drift
    path = File.join(Dir.mktmpdir, 'offset.json')
    reader, io = reader_for(['-0.050 kgT'] * 200, offset_file: path)
    sleep 0.1
    assert_equal [:ok, -50], reader.zero!
    assert_includes io.writes, ScaleReader::CMD_ZERO
    assert_equal [:ok, 0], reader.weight
    assert_equal(-50, JSON.parse(File.read(path))['offset_grams'])
  end

  def test_zero_refused_with_load
    reader, = reader_for(['1.000 kgT'] * 200)
    sleep 0.1
    status, = reader.zero!
    assert_equal :error, status
  end

  def test_reconnects_after_io_error
    calls = 0
    factory = lambda do
      calls += 1
      raise Errno::ENOENT, '/dev/ttyUSB0' if calls == 1

      ScriptedIO.new(['0.200 kgT'] * 10)
    end
    reader = ScaleReader.new(io_factory: factory, logger: nil).start
    assert_equal [:ok, 200], reader.weight(timeout: 4)
  end
end
