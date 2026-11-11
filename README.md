# ScaleServer

This is a simple server that reads weight values from a Gram Xtrem F scale connected to a serial port and serves the closest weight value in grams on the root path. It uses the Puma web server to handle incoming HTTP requests and the serialport library to communicate with the serial port. The server is started using the Rack::Handler::Puma.run method and listens for incoming requests on port 8000. The weight values are read from the serial port using the serial.gets method and are extracted from the lines that contain the "kgT" pseudounit. The weight values are then converted from kgT to grams and stored in an array. The mean and standard deviation of the weight values are calculated, and outliers are removed from the array. The closest weight value to the mean is then returned as the response. 

## Installation

1. Clone the repository to your local machine.

```
git clone git@github.com:squared-one/scaleserver.git
```

2. Install the required gems by running `bundle install --path vendor/bundle` in the project directory.

## Usage

To start the server, run the following command in the project directory:

```
bundle exec puma ./scale.rb -b 0.0.0.0
```

This will start the server on port 8000 and bind it to the `0.0.0.0` IP address, which means it will be accessible from any network interface.

To access the server, open a web browser and navigate to `http://localhost:8000/` in development or `http://squared-scale-pi-1.local` in production. You should see an integer displayed in your browser.

To calibrate the scale, navigate to `http://localhost:8000/calibrate` in development or `http://squared-scale-pi-1.local/calibrate` in production.

## Testing

To test the server without a real serial port, you can set the `port` variable to `'test'` in the `scale.rb` file. This will cause the server to use a `StringIO` object to simulate the serial input.

```ruby
port = 'test'
```

When the `port` variable is set to `'test'`, the server will serve a random integer on the root path.

## Installing and Using the Systemd Service

1. Copy the `scale.service` file to the `/etc/systemd/system/` directory on your Raspberry Pi. You can use the following command to copy the file:

   ```
   sudo cp scale.service /etc/systemd/system/
   ```

   Make sure to replace `scale.service` with the name of your service file if it is different.

2. Open the `scale.service` file in a text editor and replace the `User` value with `scale` or the appropriate user for your system. For example, if you want to run the service as the `scale` user, you would set the `User` value to `scale`.

3. Replace the `WorkingDirectory` value with the appropriate directory for your system. For example, if you cloned the Scale Server repository to the `/home/scale/scale-server` directory, you would set the `WorkingDirectory` value to `/home/scale/scale-server`.

4. Save the `scale.service` file and exit the text editor.

5. Run the following command to reload the systemd configuration:

   ```
   sudo systemctl daemon-reload
   ```

6. Run the following command to enable the `scale` service to start automatically at boot:

   ```
   sudo systemctl enable scale
   ```

7. Run the following command to start the `scale` service:

   ```
   sudo systemctl start scale
   ```

   The Scale Server should now be running as a systemd service.

8. To check the status of the `scale` service, run the following command:

   ```
   sudo systemctl status scale
   ```

   This will display the current status of the `scale` service, including whether it is running or stopped.

9. To stop the `scale` service, run the following command:

   ```
   sudo systemctl stop scale
   ```

10. To restart the `scale` service, run the following command:

   ```
   sudo systemctl restart scale
   ```

   This will stop and start the `scale` service.

11. To access the Scale Server, open a web browser and navigate to `http://squared-scale-pi-1.local:8000/`. You should see an integer displayed in your browser.

## Endpoints

- `GET /` – stable weight in grams as plain text (used by the `COMMAND-SCALE` barcode). `503` with a Czech message when the scale sends no data, is below zero / in error, is not stable, or shows a negative weight.
- `GET /live` – immediate state as JSON (`{"status":"ok","grams":1235}` or `{"status":"error","reason":"no_weight","message":"…"}`), polled by the scale panel in Squared picking.
- `GET /weigh` – like `/`, as JSON.
- `POST /zero` (legacy `GET /calibrate`) – sends the zero command and checks the scale reads 0 g. The scale refuses when the zero drifted outside its zero range; then only a power cycle with an empty platform helps.
- `GET /status` – JSON for diagnostics (last raw frame, readings window, last error).

A background thread keeps the scale in continuous mode (~10 frames/s) and remembers the last readings, so requests answer immediately. The weight is the median of the last 5 readings, only when they differ by at most 10 g.

## Scale frames (Gram Xtrem F, observed 2026-11-11)

```
STX 0100r01071AW   1.025kgT   0.000kgS01062 ETX CRLF   weight (gross, kgT)
STX 0100r010002487C ETX CRLF                           no weight: below zero or error state
STX 0100e101101054 ETX CRLF                            ack of a command
```

When only the short `r010002` frame comes, the scale's zero drifted below the range in which it reports weight. The zero command is acknowledged but does not fix it; unplug the scale for 10 s with an empty platform.

## Deployment on the dispatch PC

`ssh expedice` (192.168.1.155, user `squared-expedice`), code in `~/squared-scale`, service `scale` runs `bundle exec puma ./scale.rb` as root. Copy `scale.rb` + `scale_reader.rb`, then `ssh -t expedice sudo ~/squared-scale/deploy-sudo.sh`.

## Configuration

- `SCALE_PORT` – serial device (default `/dev/ttyUSB0`), `tcp://<ip>:<port>` for the Wi-Fi/Ethernet module, or `test` for a simulated scale.
- `SCALE_BAUD` (9600), `PORT` (8000), `BIND` (127.0.0.1), `SCALE_OFFSET_FILE`.

Tests: `ruby -I. test_scale_reader.rb`

## Known issues

1. Sometimes Permission denied for ttyUSB0 occurs: add the `scale` user to the `dialout` group (`sudo usermod -aG dialout scale`).

## License

This project is licensed under the MIT License. See the `LICENSE` file for details.

