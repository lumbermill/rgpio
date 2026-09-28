#!/usr/bin/env ruby

# Find the per-channel balance that makes an RGB LED's white look white.
#
# The three dies are not equally bright for equal duty — red drops about 1.9 V
# against 3.1 V for green and blue, so on a 3.3 V line with equal resistors the
# channels get very different currents, and the white ends up tinted. This walks
# through candidate scales with the LED showing white, prints each one, and waits
# for Enter so you can look before it moves on.
#
# Wiring: the same as examples/rgb_led.rb.
#   GPIO17 (pin 11) -- 1k -- red, GPIO27 (pin 13) -- 1k -- green,
#   GPIO22 (pin 15) -- 1k -- blue, common leg -- GND (pin 9)
#
# Run:
#   ruby examples/rgb_balance.rb
#
# Note the scale that looks neutral and pass it from then on:
#   Rgpio::RGBLED.new(red: 17, green: 27, blue: 22, balance: [0.7, 1.0, 0.6])
#
# Only reducing is possible: whichever channel is weakest stays at 1.0 and the
# others come down to meet it, so a tinted white costs some brightness.

require_relative "../lib/rgpio"

RED_GPIO = 17
GREEN_GPIO = 27
BLUE_GPIO = 22

# Each step keeps the weakest-looking channel at full and pulls one or two of the
# others down. Green is usually the weak one on 3.3 V, which reads as a blue or
# magenta white; the later rows dim red and blue further.
CANDIDATES = [
  [1.0, 1.0, 1.0],
  [0.8, 1.0, 0.8],
  [0.7, 1.0, 0.7],
  [0.6, 1.0, 0.6],
  [0.5, 1.0, 0.5],
  [0.7, 1.0, 0.5],
  [0.5, 1.0, 0.7],
  [1.0, 0.8, 0.8],
].freeze

$stdout.sync = true

led = Rgpio::RGBLED.new(red: RED_GPIO, green: GREEN_GPIO, blue: BLUE_GPIO)
led.color = :white

puts "The LED is showing white. Press Enter to try the next balance, Ctrl-C to stop."
puts

begin
  CANDIDATES.each_with_index do |balance, i|
    led.balance = balance
    puts format("%d/%d  balance = %s", i + 1, CANDIDATES.size, balance.inspect)
    $stdin.gets
  end

  puts "Through all of them. Re-run to compare the ones you liked."
rescue Interrupt
  puts "\nStopped."
ensure
  led.off
  led.close
end
