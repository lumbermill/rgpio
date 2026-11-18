#!/usr/bin/env ruby

# Sweep an RC servo from the hardware PWM peripheral instead of software PWM.
# Same sweep as examples/servo.rb, but the pulses are timed by the SoC, so the
# servo holds perfectly still, even on a Pi Zero where software PWM trembles.
#
# Wiring:
#   GPIO12 (pin 32)           -- servo signal (usually yellow or orange)
#   5 V   (pin 2 or 4)        -- servo power (red)
#   GND   (pin 6 or any GND)  -- servo ground (brown or black)
#
# Needs a line in /boot/firmware/config.txt, then a reboot. Unlike
# examples/servo.rb, this one does not run without it:
#
#   dtoverlay=pwm-2chan,pin=12,func=4,pin2=13,func2=4
#
# That gives GPIO12 and GPIO13, the same line on a Pi 5, Pi 4 and Pi Zero. Add
# it at the very end of the file, under [all]: a line below [cm5] or [pi5] is
# read on that board only, and silently ignored on the others. Check with
# `ls /sys/class/pwm/` (a pwmchip should be listed) and `pinctrl get 12`
# (expect a0). See "Hardware PWM Usage" in docs/guide.md for the other pins.
#
# Run (the last phase holds still for HOLD seconds, 15 by default):
#   ruby examples/servo_with_hw.rb
#   ruby examples/servo_with_hw.rb 60

require_relative "../lib/rgpio"

SERVO_GPIO = 12
HOLD = Integer(ARGV.fetch(0, 15))

# Say what the device is doing as it happens, so the terminal and the bench agree.
$stdout.sync = true

begin
  servo = Rgpio::Servo.new(SERVO_GPIO, min_pulse_us: 1000, max_pulse_us: 2000, pwm: :hardware)
rescue Rgpio::PWMError, ArgumentError => e
  abort "#{e.message}\n\nHardware PWM on GPIO#{SERVO_GPIO} needs this line at the end of " \
        "/boot/firmware/config.txt, and a reboot:\n  dtoverlay=pwm-2chan,pin=12,func=4,pin2=13,func2=4"
end

pwm = servo.pwm
puts "Servo on GPIO#{SERVO_GPIO}, #{pwm.frequency.round} Hz frames from hardware PWM " \
     "(pwmchip#{pwm.chip_num} channel #{pwm.channel}, board #{pwm.board}). Ctrl-C to stop."

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

  puts "holding at +45 degrees for #{HOLD} s — it should not twitch at all"
  servo.angle = 45
  sleep HOLD

  puts "detaching — the horn goes limp and the servo stops drawing current"
  servo.detach
  sleep 1
rescue Interrupt
  puts "\nStopped."
ensure
  servo.close
end
