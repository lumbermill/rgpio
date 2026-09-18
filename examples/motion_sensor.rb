#!/usr/bin/env ruby

# Report movement from a PIR sensor with Rgpio::MotionSensor.
#
# Sensor: a D-SUN PIR module — the HC-SR501 layout, with a BISS0001 controller,
# a white dome, two trimmers and a three-pin mode jumper. It runs on 5 V and
# not on 3.3 V (the onboard regulator needs the headroom), and its OUT pin
# swings 0/3.3 V because the BISS0001 sits behind that regulator, so it drives
# a GPIO line directly.
#
# Some clones drive OUT to VCC instead, and 5 V on a GPIO pin damages the Pi.
# With an unfamiliar module, leave OUT disconnected, power the sensor, wave at
# it and measure OUT against GND: 3.3 V is safe to wire up, 5 V needs a divider
# (OUT -- 10 kΩ -- GPIO4 -- 20 kΩ -- GND) or a level shifter.
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
# sensor to adjust sensitivity and hold time while this is running — which
# trimmer is which varies by batch, so turn one and watch whether the length of
# a detection changes.
#
# Two things about the module shape what this prints. It settles for up to a
# minute after power-on and fires at random until it has, so detections inside
# the warm-up window are reported but left out of the count. And OUT stays high
# for the hold time after a detection, so continuous movement counts once per
# hold period rather than once per movement. Both timings come from resistors
# and capacitors on the board and vary between clones: the hold time bottoms
# out at 0.9 s on the D-SUN board this was written against, where the HC-SR501
# datasheet says 5 s. Measure rather than assume.
#
# These modules also trigger on power-rail noise as readily as on movement —
# the BISS0001 front end has a lot of gain and the Pi's 5 V pin is a switching
# regulator's output. If detections arrive with nothing moving, put 100 µF and
# 0.1 µF across VCC/GND at the sensor and turn the sensitivity down.

require_relative "../lib/rgpio"

SENSOR_GPIO = 4
WARMUP_SECONDS = 60

sensor = Rgpio::MotionSensor.new(SENSOR_GPIO)

begin
  # CLOCK_MONOTONIC, not Time.now: a Pi has no RTC, so the wall clock can jump
  # by hours the moment NTP answers — often within a minute of boot.
  started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  count = 0

  # Only the watcher thread runs this block, so the counter needs no lock.
  sensor.when_motion do
    if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at < WARMUP_SECONDS
      puts "motion detected! (warming up...)"
    else
      count += 1
      puts "motion detected! #{count}"
    end
  end

  puts "Watching GPIO#{SENSOR_GPIO}, counting after #{WARMUP_SECONDS} s of warm-up. Press Ctrl-C to stop."
  Rgpio.pause
ensure
  sensor.close
end
