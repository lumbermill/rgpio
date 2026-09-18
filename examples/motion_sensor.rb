#!/usr/bin/env ruby
# frozen_string_literal: true

# Report movement from a PIR sensor with Rgpio::MotionSensor.
#
# Wiring (PIR sensor):
#   VCC -- 5 V (pin 2)
#   GND -- GND (pin 6)
#   OUT -- GPIO4 (pin 7)
#
# Run:
#   ruby examples/motion_sensor.rb
#
# Move in front of the sensor; stop with Ctrl-C. Use the two trimmers on the
# sensor to adjust sensitivity and hold time while this is running.

require_relative "../lib/rgpio"

SENSOR_GPIO = 4

sensor = Rgpio::MotionSensor.new(SENSOR_GPIO)

begin
  sensor.when_motion { puts "motion detected!" }

  puts "Watching GPIO#{SENSOR_GPIO}. Press Ctrl-C to stop."
  Rgpio.pause
ensure
  sensor.close
end
