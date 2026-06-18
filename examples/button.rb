#!/usr/bin/env ruby
# frozen_string_literal: true

# Read a button connected to GPIO27 using hardware edge detection.
# Prints a line each time the button is pressed or released.
#
# Wiring (active-low with internal pull-up):
#   Pi 5 pin 13 (GPIO27) -- one leg of button
#   Button other leg     -- GND (pin 14 or any GND pin)
#
# Run:
#   sudo ruby examples/button.rb
#
# Ctrl-C to stop.

require_relative "../lib/libgpiod_ffi"

GPIO_BUTTON = 27

puts "libgpiod version: #{LibgpiodFFI.version}"
puts "Watching GPIO#{GPIO_BUTTON} for button events. Press Ctrl-C to stop."

LibgpiodFFI::Chip.open("/dev/gpiochip0") do |chip|
  puts "Chip: #{chip.label}"

  request = chip.request_lines(
    offsets:    [GPIO_BUTTON],
    direction:  :input,
    edge:       :both,
    bias:       :pull_up,   # internal pull-up; button connects pin to GND
    active_low: true,       # treat LOW (button pressed) as :active
    consumer:   "libgpiod-ffi-button"
  )

  begin
    loop do
      # Block until an edge event arrives (no timeout)
      events = request.read_edge_events(timeout: nil)
      events.each do |event|
        label = event[:type] == :rising ? "RELEASED" : "PRESSED "
        ts_ms = event[:timestamp_ns] / 1_000_000.0
        puts "[#{ts_ms.round(3)} ms] GPIO#{event[:offset]} #{label}"
      end
    end
  rescue Interrupt
    puts "\nStopped."
  ensure
    request.release
  end
end
