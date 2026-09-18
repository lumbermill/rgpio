#!/usr/bin/env ruby
# frozen_string_literal: true

# React to a switch with the high-level Rgpio::Button device, which runs the
# callbacks on a background thread. For the same thing written against
# Chip/LineRequest directly, see examples/lowlevel/button.rb.
#
# Wiring — this circuit puts the switch on the 3.3 V side, so the line needs
# the internal pull-down that Button uses by default:
#   3.3 V (pin 1) -- switch -- 1 kΩ resistor -- GPIO4 (pin 7)
#
# For the other common wiring (switch to GND) pass pull_up: true instead:
#   button = Rgpio::Button.new(4, pull_up: true)
#
# Run:
#   ruby examples/button.rb
#
# Press and release the switch; stop with Ctrl-C.

require_relative "../lib/rgpio"

BUTTON_GPIO = 4

button = Rgpio::Button.new(BUTTON_GPIO)

begin
  button.when_pressed  { puts "Pressed" }
  button.when_released { puts "Released" }

  puts "Waiting for GPIO#{BUTTON_GPIO}. Press Ctrl-C to stop."
  Rgpio.pause
ensure
  button.close
end
