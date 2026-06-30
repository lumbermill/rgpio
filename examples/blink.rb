#!/usr/bin/env ruby
# frozen_string_literal: true

# Blink an LED connected to GPIO17.
#
# Wiring:
#   Pi 5 pin 11 (GPIO17) --[330 Ω]-- LED anode
#   LED cathode          -- GND (pin 9 or any GND pin)
#
# Run:
#   ruby examples/blink.rb
#
# Ctrl-C to stop.

require_relative "../lib/rgpio"

GPIO_LED    = 17
BLINK_DELAY = 0.5 # seconds

puts "libgpiod version: #{Rgpio.version}"
puts "Blinking GPIO#{GPIO_LED} at #{1.0 / (BLINK_DELAY * 2)} Hz. Press Ctrl-C to stop."

# No path given → auto-detect the header GPIO controller, so the same
# script runs unchanged on Pi 5 / Pi 4 / Pi Zero.
Rgpio::Chip.open do |chip|
  puts "Chip: #{chip.path} #{chip.label} (#{chip.num_lines} lines)"

  request = chip.request_lines(
    offsets:   [GPIO_LED],
    direction: :output,
    consumer:  "rgpio-blink"
  )

  begin
    loop do
      request.set_value(GPIO_LED, :active)
      sleep BLINK_DELAY
      request.set_value(GPIO_LED, :inactive)
      sleep BLINK_DELAY
    end
  rescue Interrupt
    puts "\nStopped."
  ensure
    request.set_value(GPIO_LED, :inactive)
    request.release
  end
end
