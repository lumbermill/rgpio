#!/usr/bin/env ruby

# Fade an LED up and down with PWM, on any GPIO line.
#
# Wiring (the same as examples/led.rb):
#   GPIO4 (pin 7) -- 1k resistor -- LED anode (long leg)
#   LED cathode (short leg) -- GND (pin 6)
#
# No dtoverlay and no config.txt entry: the brightness comes from
# Rgpio::SoftwarePWM, which drives any line. On GPIO12/13/18/19 you can pass
# pwm: :hardware instead for a peripheral-timed waveform.
#
# Run:
#   ruby examples/pwm_led.rb

require_relative "../lib/rgpio"

LED_GPIO = 4
STEPS = 50
STEP_DELAY = 0.02

led = Rgpio::PWMLED.new(LED_GPIO)
puts "Fading the LED on GPIO#{LED_GPIO} at #{led.frequency} Hz. Ctrl-C to stop."

begin
  3.times do
    (0..STEPS).each do |i|
      led.value = i / STEPS.to_f
      sleep STEP_DELAY
    end
    (0..STEPS).reverse_each do |i|
      led.value = i / STEPS.to_f
      sleep STEP_DELAY
    end
  end

  puts "Half brightness for a second — the level holds with no further calls."
  led.value = 0.5
  sleep 1
rescue Interrupt
  puts "\nStopped."
ensure
  led.close
end
