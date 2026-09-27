#!/usr/bin/env ruby

# Read the ambient temperature from an ADT7410 I2C sensor once a second.
#
# Wiring (the sensor breakout runs on 3.3 V):
#   3.3V   (pin 1)          -- VDD
#   GND    (pin 9)          -- GND
#   GPIO2  (pin 3, SDA)     -- SDA
#   GPIO3  (pin 5, SCL)     -- SCL
#
# Prerequisite — the header I2C bus must be enabled:
#   sudo raspi-config nonint do_i2c 0     # or: dtparam=i2c_arm=on in config.txt
#   sudo reboot
#
# Verify:
#   ls /dev/i2c-1
#   i2cdetect -y 1        # the sensor answers at 0x48 (0x49..0x4b if A0/A1 are high)
#
# Run:
#   ruby examples/temperature.rb

require_relative "../lib/rgpio"

ADDRESS = 0x48
INTERVAL = 1.0

$stdout.sync = true # so the readings still appear when piped to a file

puts "I2C buses: #{Rgpio::I2C.buses.inspect}"

sensor = Rgpio::ADT7410.new(address: ADDRESS)

unless sensor.detected?
  warn format("No ADT7410 at 0x%02x (ID register read back 0x%02x).", ADDRESS, sensor.id)
  warn "Check the wiring and `i2cdetect -y 1`."
  exit 1
end

puts format("ADT7410 at 0x%02x, ID 0x%02x, %d-bit mode. Ctrl-C to stop.", ADDRESS, sensor.id, sensor.resolution)

# The first conversion after power-up is still running for ~240 ms.
sleep Rgpio::ADT7410::CONVERSION_TIME

begin
  loop do
    puts format("%.4f degC", sensor.temperature)
    sleep INTERVAL
  end
rescue Interrupt
  puts "\nStopped."
ensure
  sensor.close
end
