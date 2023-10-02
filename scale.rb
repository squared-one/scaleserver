require 'rubygems'
require 'puma'
require 'rack'
require 'rack/handler/puma'
require 'serialport'
require 'stringio'

# Configure serial port
port = '/dev/ttyUSB0' # Replace with the path to your serial port
port = '/dev/tty.usbserial-FTC2F1C1' if RUBY_PLATFORM =~ /darwin/
baud_rate = 9600
data_bits = 8
stop_bits = 1
parity = SerialPort::NONE
separator = "\r\n"
number_of_measurements = 7

def process_line(line)
    puts "Received line: #{line}"
end

# Serve integer from serial input on root path
serial = SerialPort.new(port, baud_rate, data_bits, stop_bits, parity)
serial.read_timeout = 1000

# Define Rack application
app = Proc.new do |env| 
    weights =  []

    # Send command to scale to start sending weight values
    serial.write("\u000200FFE10110000\u0003\r\n")

    start_time = Time.now

    # Read weight values from serial port
    number_of_measurements.times do
        # Read a line from the serial port
        line = serial.gets(separator)

        # Extract the weight value from the line if it contains the "kgT" pseudounit
        begin
            if line.include?("kgT")
                # Extract the weight value from the second column of the line
                weight_kgt = line.split[1].to_f

                # Convert the weight value from kgT to grams
                weight_grams = (weight_kgt * 1000).to_i

                # Store the weight value in the weights array
                weights << weight_grams 
            end
        rescue NoMethodError
        end
    end

    end_time = Time.now

    # Stop sending weight values from the scale
    serial.write("\u000200FFE10100000\u0003\r\n")

    # Calculate the mean and standard deviation of the weight values
    mean = weights.sum / weights.size.to_f
    std_dev = Math.sqrt(weights.map { |w| (w - mean) ** 2 }.sum / weights.size)

    # Identify outliers as values that are more than 3 standard deviations away from the mean
    outliers = weights.select { |w| (w - mean).abs > 3 * std_dev }

    # Remove outliers from the weights array
    weights -= outliers

    # Calculate the mean of the remaining weight values
    mean = weights.sum / weights.size.to_f

    # The closest value to the real weight is the weight value that is closest to the mean
    closest_value = weights.min_by { |w| (w - mean).abs }

    # Return the closest weight value as a plain text response
    ['200', {'Content-Type' => 'text/plain'}, [closest_value.to_s]]
end

# Start Puma server
Rack::Handler::Puma.run(app, Port: 8000)

# Stop sending weight values from the scale and close the serial port
serial.write("\u000200FFE10100000\u0003\r\n")
serial.close