#!/usr/bin/env ruby
# frozen_string_literal: true

# Drive a standard RC servo motor via hardware PWM on GPIO18.
#
# Wiring:
#   GPIO18 (pin 12, RP1 PWM channel 2) -- servo signal wire (usually yellow/orange)
#   5 V    (pin 2 or 4)                -- servo power (red)
#   GND    (pin 6 or any GND)          -- servo ground (brown/black)
#
# Prerequisites — add to /boot/firmware/config.txt and reboot:
#   dtoverlay=pwm,pin=18,func=4
#
# Verify PWM is available:
#   ls /sys/class/pwm/
#
# Run:
#   sudo ruby examples/servo.rb
#
# The servo sweeps from minimum to maximum position and back, three times.

require_relative "../lib/libgpiod_ffi"

SERVO_GPIO     = 18
FREQUENCY_HZ   = 50      # Standard servo frequency (20 ms period)
PULSE_MIN_US   = 500     # 0.5 ms — full counter-clockwise (varies by servo)
PULSE_CENTER_US = 1500   # 1.5 ms — center position
PULSE_MAX_US   = 2500    # 2.5 ms — full clockwise (varies by servo)
STEP_US        = 10      # microseconds per step
STEP_DELAY     = 0.005   # seconds between steps

def sweep(pwm, from_us, to_us, step_us, delay)
  steps = ((to_us - from_us) / step_us.to_f).ceil.abs
  direction = to_us > from_us ? 1 : -1
  steps.times do |i|
    pwm.pulse_width_us = from_us + direction * i * step_us
    sleep delay
  end
  pwm.pulse_width_us = to_us
  sleep delay
end

puts "libgpiod version: #{LibgpiodFFI.version}"
puts "Available PWM chips: #{LibgpiodFFI::HardwarePWM.available_chips.inspect}"
puts "Driving servo on GPIO#{SERVO_GPIO} at #{FREQUENCY_HZ} Hz."

LibgpiodFFI::HardwarePWM.open(gpio: SERVO_GPIO) do |pwm|
  puts "Using pwmchip#{pwm.chip_num}, channel #{pwm.channel}"
  pwm.frequency  = FREQUENCY_HZ
  pwm.duty_cycle = 0.0  # start with duty=0 before enabling
  pwm.enable

  # Move to center first
  pwm.pulse_width_us = PULSE_CENTER_US
  sleep 0.5

  3.times do |run|
    puts "Sweep #{run + 1}/3: min → max → min"
    sweep(pwm, PULSE_CENTER_US, PULSE_MAX_US, STEP_US, STEP_DELAY)
    sweep(pwm, PULSE_MAX_US, PULSE_MIN_US, STEP_US, STEP_DELAY)
    sweep(pwm, PULSE_MIN_US, PULSE_CENTER_US, STEP_US, STEP_DELAY)
    sleep 0.3
  end

  puts "Done. Returning to center."
  pwm.pulse_width_us = PULSE_CENTER_US
  sleep 0.5
end

puts "PWM disabled and unexported."
