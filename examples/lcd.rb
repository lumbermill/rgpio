#!/usr/bin/env ruby

# Print text on an ST7032 character LCD (Akizuki AQM0802 8x2 / AQM1602 16x2).
#
# Wiring (module runs on 3.3 V; the Akizuki kit board carries the pull-ups):
#   3.3V   (pin 1)          -- VDD
#   GND    (pin 9)          -- GND
#   GPIO2  (pin 3, SDA)     -- SDA
#   GPIO3  (pin 5, SCL)     -- SCL
#
# Prerequisite — the header I2C bus must be enabled:
#   sudo raspi-config nonint do_i2c 0     # or: dtparam=i2c_arm=on in config.txt
#   sudo reboot
#
# Verify:
#   i2cdetect -y 1        # the display answers at 0x3e
#
# Run:
#   ruby examples/lcd.rb
#
# A blank display with a sensible-looking backlight is almost always contrast;
# pass contrast: 0..63 to ST7032.new until the characters appear.

require_relative "../lib/rgpio"

COLUMNS = 8 # 16 for an AQM1602

Rgpio::ST7032.open(columns: COLUMNS) do |lcd|
  lcd.message = "Hello\nrgpio"
  sleep 2

  # The cursor addresses each row independently.
  lcd.clear
  3.times do |i|
    lcd.move_to(0, 0)
    lcd.print("count".ljust(COLUMNS))
    lcd.move_to(0, 1)
    lcd.print((i + 1).to_s.ljust(COLUMNS))
    sleep 1
  end

  lcd.message = "bye"
  sleep 1
  lcd.clear
end

puts "Done."
