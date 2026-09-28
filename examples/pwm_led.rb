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
HOLD = 3

# Say what the LED is doing as it happens, so the terminal and the bench agree.
$stdout.sync = true

led = Rgpio::PWMLED.new(LED_GPIO)
puts "LED on GPIO#{LED_GPIO}, #{led.frequency} Hz. Ctrl-C to stop."

begin
  puts "1) fading up and down, three times"
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

  puts "2) holding fixed levels for #{HOLD} s each — one call per level, no loop"
  [0.05, 0.25, 0.5, 1.0, 0.5].each do |level|
    puts format("   value = %.2f  (%.0f%% duty)", level, level * 100)
    led.value = level
    sleep HOLD
  end

  puts "3) off"
  led.off
  sleep 1
rescue Interrupt
  puts "\nStopped."
ensure
  led.close
end
