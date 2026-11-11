require 'rubygems'
require 'json'
require 'puma'
require 'rack'
require 'rack/handler/puma'
require_relative 'scale_reader'

# SCALE_PORT: serial device path, "tcp://host:port" (Wi-Fi module) or "test"
default_port = RUBY_PLATFORM =~ /darwin/ ? '/dev/tty.usbserial-FTC2F1C1' : '/dev/ttyUSB0'
port = ENV.fetch('SCALE_PORT', default_port)
baud_rate = ENV.fetch('SCALE_BAUD', '9600').to_i
http_port = ENV.fetch('PORT', '8000').to_i

io_factory =
  case port
  when 'test'
    -> { FakeScaleIO.new }
  when %r{\Atcp://([^:/]+):(\d+)}
    host = Regexp.last_match(1)
    tcp_port = Regexp.last_match(2).to_i
    -> { TcpScaleIO.new(host, tcp_port) }
  else
    require 'serialport'
    lambda do
      serial = SerialPort.new(port, baud_rate, 8, 1, SerialPort::NONE)
      serial.read_timeout = 1000
      serial
    end
  end

reader = ScaleReader.new(io_factory: io_factory).start

text = lambda do |state|
  body = state[:status] == :ok ? state[:grams] : state[:message]
  [state[:status] == :ok ? '200' : '503', { 'Content-Type' => 'text/plain; charset=utf-8' }, [body.to_s]]
end
json = ->(state) { ['200', { 'Content-Type' => 'application/json' }, [JSON.generate(state)]] }

app = proc do |env|
  case env['PATH_INFO']
  when '/'      then text.call(reader.weight)             # plain grams, used by COMMAND-SCALE
  when '/live'  then json.call(reader.current_state)      # immediate state for the picking panel
  when '/weigh' then json.call(reader.weight)             # waits for a stable weight
  when '/zero', '/calibrate'
    state = reader.zero!
    env['PATH_INFO'] == '/calibrate' ? text.call(state) : json.call(state)
  when '/status' then ['200', { 'Content-Type' => 'application/json' }, [JSON.pretty_generate(reader.status)]]
  else ['404', { 'Content-Type' => 'text/plain' }, ['Not found']]
  end
end

at_exit { reader.stop }

Rack::Handler::Puma.run(app, Port: http_port, Host: ENV.fetch('BIND', '127.0.0.1'), Threads: '0:4')
