#!/usr/bin/env ruby

# Read all eight channels of an MCP3208 analogue-to-digital converter.
#
# Wiring (MCP3208 in a 16-pin DIP, pin 1 at the notch):
#   pin 1-8   CH0..CH7   -- analogue inputs; a potentiometer's wiper on CH0
#   pin 9     DGND       -- GND
#   pin 10    CS/SHDN    -- GPIO8  (pin 24, CE0)
#   pin 11    DIN        -- GPIO10 (pin 19, MOSI)
#   pin 12    DOUT       -- GPIO9  (pin 21, MISO)
#   pin 13    CLK        -- GPIO11 (pin 23, SCLK)
#   pin 14    AGND       -- GND
#   pin 15    VREF       -- 3.3 V  (pin 1)
#   pin 16    VDD        -- 3.3 V
#
# A potentiometer to try it with: one end to 3.3 V, the other to GND, the wiper
# to CH0. Unconnected channels float and read whatever is nearby, which is not a
# fault.
#
# Prerequisite — the header SPI bus must be enabled:
#   sudo raspi-config nonint do_spi 0     # or: dtparam=spi=on in config.txt
#
# Verify:
#   ls /dev/spidev0.0
#
# Run:
#   ruby examples/adc.rb

require_relative "../lib/rgpio"

INTERVAL = 0.5
REFERENCE_VOLTAGE = 3.3

$stdout.sync = true

puts "spidev buses: #{Rgpio::SPI.devices.inspect}"

adc = Rgpio::MCP3208.new(reference_voltage: REFERENCE_VOLTAGE)
puts "MCP3208 on #{adc.spi.path} at #{adc.spi.speed_hz / 1000} kHz. Ctrl-C to stop."
puts "        #{(0...adc.channels).map { |c| format("%7s", "CH#{c}") }.join}"

begin
  loop do
    codes = adc.read_all
    puts "raw     #{codes.map { |v| format("%7d", v) }.join}"
    puts "volts   #{codes.map do |v|
      format("%7.3f", v / (Rgpio::MCP3208::RESOLUTION - 1).to_f * REFERENCE_VOLTAGE)
    end.join}"
    sleep INTERVAL
  end
rescue Interrupt
  puts "\nStopped."
ensure
  adc.close
end
