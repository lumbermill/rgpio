#!/usr/bin/env ruby

# Cycle a full-colour LED through the corners of the colour cube, then mix.
#
# Wiring (common cathode: the long leg is the common one and goes to GND):
#   GPIO17 (pin 11) -- 1k resistor -- red leg
#   GPIO27 (pin 13) -- 1k resistor -- green leg
#   GPIO22 (pin 15) -- 1k resistor -- blue leg
#   common leg      -- GND (pin 9)
#
# For a common-anode LED, tie the common leg to 3.3 V and pass active_low: true.
#
# White comes out tinted unless the channels are scaled to match — see BALANCE
# below and examples/rgb_balance.rb.
#
# GPIO2/3/4 work just as well (the pins the book uses) as long as the I2C bus is
# not enabled, since GPIO2/3 are SDA/SCL. Three software PWM channels need no
# dtoverlay; the hardware PWM peripheral could not do this at all, because the
# 40-pin header exposes only two of its channels.
#
# Run:
#   ruby examples/rgb_led.rb

require_relative "../lib/rgpio"

RED_GPIO = 17
GREEN_GPIO = 27
BLUE_GPIO = 22
HOLD = 2

# Per-channel scale that makes white look white. This is the value the LED used
# for verification wanted — red at full, green and blue trimmed 20% — and it is
# a property of the part, not of the gem: run examples/rgb_balance.rb to find
# yours. [1.0, 1.0, 1.0] is the gem's default, i.e. no correction.
BALANCE = [1.0, 0.8, 0.8].freeze

# Say what the device is doing as it happens, so the terminal and the bench agree.
$stdout.sync = true

# Walk from one colour to another, a step at a time.
def fade(led, from, to, steps: 50, delay: 0.02)
  (0..steps).each do |i|
    position = i / steps.to_f
    led.color = from.zip(to).map { |a, b| a + ((b - a) * position) }
    sleep delay
  end
end

led = Rgpio::RGBLED.new(red: RED_GPIO, green: GREEN_GPIO, blue: BLUE_GPIO, balance: BALANCE)
puts "RGB LED on GPIO#{RED_GPIO} (red) / #{GREEN_GPIO} (green) / #{BLUE_GPIO} (blue). Ctrl-C to stop."
puts "1) each named colour for #{HOLD} s"

begin
  Rgpio::RGBLED::COLORS.each_key do |name|
    next if name == :off

    puts "  #{name}"
    led.color = name
    sleep HOLD
  end

  puts "2) fading red into blue and back, twice"
  2.times do
    fade(led, Rgpio::RGBLED::COLORS[:red], Rgpio::RGBLED::COLORS[:blue])
    fade(led, Rgpio::RGBLED::COLORS[:blue], Rgpio::RGBLED::COLORS[:red])
  end
rescue Interrupt
  puts "\nStopped."
ensure
  led.off
  led.close
end
