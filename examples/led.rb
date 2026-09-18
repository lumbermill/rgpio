#!/usr/bin/env ruby

# Blink an LED with the high-level Rgpio::LED device.
# For the same thing written against Chip/LineRequest directly, see
# examples/lowlevel/blink.rb.
#
# Wiring:
#   GPIO4 (pin 7) -- 1 kΩ resistor -- LED anode (long leg)
#   LED cathode (short leg) -- GND (pin 6 or any GND)
#
# Run:
#   ruby examples/led.rb
#
# The LED turns on and off five times at one-second intervals.

require_relative "../lib/rgpio"

LED_GPIO = 4

led = Rgpio::LED.new(LED_GPIO)

begin
  5.times do
    led.on
    sleep 1
    led.off
    sleep 1
  end
ensure
  led.close
end
