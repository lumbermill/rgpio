#!/usr/bin/env ruby

# Drive a DC motor forward and backward with Rgpio::Motor through a DRV8835
# two-input motor driver.
#
# Wiring (DRV8835):
#   VM, GND    -- motor power supply (+ / -)
#   VCC        -- 3.3 V (pin 1)
#   AOUT1/2    -- motor A terminals
#   AIN1       -- GPIO2  (forward)
#   AIN2       -- GPIO14 (backward)
#
# GPIO2 is used for forward rather than GPIO4, which can already be claimed by
# another consumer and then fails the request as busy.
#
# Run:
#   ruby examples/motor.rb
#
# The motor runs forward for five seconds, then backward, until Ctrl-C.

require_relative "../lib/rgpio"

motor = Rgpio::Motor.new(forward: 2, backward: 14)

begin
  loop do
    puts "forward"
    motor.forward
    sleep 5
    puts "backward"
    motor.backward
    sleep 5
  end
rescue Interrupt
  puts "\nStopping."
ensure
  motor.close
end
