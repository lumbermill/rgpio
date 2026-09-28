#!/usr/bin/env ruby

# Turn a knob, change an LED's brightness: an MCP3208 channel driving a PWMLED.
#
# Wiring: the MCP3208 as in examples/adc.rb, plus
#   potentiometer  -- one end to 3.3 V, the other to GND, wiper to CH0
#   GPIO4 (pin 7)  -- 1k resistor -- LED anode, LED cathode -- GND
#
# Run:
#   ruby examples/adc_led.rb

require_relative "../lib/rgpio"

KNOB_CHANNEL = 0
LED_GPIO = 4
INTERVAL = 0.02

$stdout.sync = true

adc = Rgpio::MCP3208.new
led = Rgpio::PWMLED.new(LED_GPIO)

puts "Turn the knob on CH#{KNOB_CHANNEL} to dim the LED on GPIO#{LED_GPIO}. Ctrl-C to stop."

begin
  last_shown = nil
  loop do
    level = adc.value(KNOB_CHANNEL)
    led.value = level

    # Only redraw when it moves, so a still knob does not scroll the terminal.
    percent = (level * 100).round
    if percent != last_shown
      puts format("CH%d = %4.2f  (%3d%%)  %s", KNOB_CHANNEL, level, percent, "#" * (percent / 2))
      last_shown = percent
    end
    sleep INTERVAL
  end
rescue Interrupt
  puts "\nStopped."
ensure
  led.close
  adc.close
end
