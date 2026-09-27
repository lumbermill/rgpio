#!/usr/bin/env ruby

# Sweep an RC servo, positioned by value (-1..1) and by angle.
#
# Wiring:
#   GPIO4 (pin 7)             -- servo signal (usually yellow or orange)
#   5 V   (pin 2 or 4)        -- servo power (red)
#   GND   (pin 6 or any GND)  -- servo ground (brown or black)
#
# A servo under load draws more than the Pi's 5 V rail likes to give; if the Pi
# reboots mid-sweep, power the servo from its own supply with a common ground.
#
# No dtoverlay and no config.txt entry: the pulses come from Rgpio::SoftwarePWM,
# which measured 6 us of spread at this frame rate on an idle Pi 5 — about half a
# degree. On GPIO12/13/18/19 you can pass pwm: :hardware for a peripheral-timed
# pulse instead. examples/lowlevel/servo.rb drives the peripheral directly.
#
# Pulse widths vary by servo. 1000..2000 us is the range every hobby servo
# understands; widen it only as far as the datasheet allows, since a servo driven
# past its travel buzzes and heats up.
#
# Run:
#   ruby examples/servo.rb

require_relative "../lib/rgpio"

SERVO_GPIO = 4

servo = Rgpio::Servo.new(SERVO_GPIO, min_pulse_us: 1000, max_pulse_us: 2000)
puts "Servo on GPIO#{SERVO_GPIO}, #{servo.pwm.frequency} Hz frames. Ctrl-C to stop."

begin
  puts "centre (#{servo.pulse_width_us.round} us)"
  sleep 1

  2.times do
    puts "one end"
    servo.min
    sleep 1
    puts "the other"
    servo.max
    sleep 1
  end

  servo.mid
  sleep 0.5

  puts "sweeping by angle"
  2.times do
    (-90..90).step(2) do |degrees|
      servo.angle = degrees
      sleep 0.01
    end
    (-90..90).step(2).reverse_each do |degrees|
      servo.angle = degrees
      sleep 0.01
    end
  end

  puts "detaching — the horn goes limp and the servo stops drawing current"
  servo.detach
  sleep 1
rescue Interrupt
  puts "\nStopped."
ensure
  servo.close
end
