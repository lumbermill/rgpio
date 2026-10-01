#!/usr/bin/env ruby

# Count the turns of a rotary encoder with Rgpio::RotaryEncoder, and reset the
# count with the push switch on its shaft through Rgpio::Button.
#
# Module: a KY-040 — CLK / DT / SW / + / GND, with 10 kΩ pull-ups on CLK and DT
# on the board. Power it from 3.3 V, never 5 V: the pull-ups go to "+", so 5 V
# there puts 5 V on the GPIO lines. SW has no pull-up on most boards, hence the
# pull_up: true on the Button below.
#
# Wiring:
#   CLK -- GPIO17 (pin 11)   phase A
#   DT  -- GPIO18 (pin 12)   phase B
#   SW  -- GPIO27 (pin 13)
#   +   -- 3.3 V  (pin 1)
#   GND -- GND    (pin 6)
#
# Run:
#   ruby examples/rotary_encoder.rb
#
# Turn the knob; the count stops at ±16. Press the knob to reset it to 0. Stop
# with Ctrl-C. If clockwise counts down, swap a: and b: (or CLK and DT).

require_relative "../lib/rgpio"

chip = Rgpio::Chip.new
encoder = Rgpio::RotaryEncoder.new(a: 17, b: 18, max_steps: 16, chip: chip)
button = Rgpio::Button.new(27, pull_up: true, chip: chip)

begin
  encoder.when_rotated_clockwise         { puts format("CW  %3d  value %+.2f", encoder.steps, encoder.value) }
  encoder.when_rotated_counter_clockwise { puts format("CCW %3d  value %+.2f", encoder.steps, encoder.value) }
  button.when_pressed do
    encoder.steps = 0
    puts "Reset"
  end

  puts "Turn the encoder on GPIO17/18. Press Ctrl-C to stop."
  Rgpio.pause
ensure
  button.close
  encoder.close
  chip.close
end
