#!/usr/bin/env ruby

# Show the ADT7410's temperature on an ST7032 LCD — the two I2C devices from
# the book on one bus, each with its own address.
#
# Wiring: both modules share the same four header pins.
#   3.3V   (pin 1)          -- VDD  (sensor and display)
#   GND    (pin 9)          -- GND  (sensor and display)
#   GPIO2  (pin 3, SDA)     -- SDA  (sensor and display)
#   GPIO3  (pin 5, SCL)     -- SCL  (sensor and display)
#
# Prerequisite — the header I2C bus must be enabled:
#   sudo raspi-config nonint do_i2c 0     # or: dtparam=i2c_arm=on in config.txt
#   sudo reboot
#
# Verify:
#   i2cdetect -y 1        # 0x3e (display) and 0x48 (sensor) both answer
#
# Run:
#   ruby examples/lcd_thermometer.rb

require_relative "../lib/rgpio"

COLUMNS = 8 # 16 for an AQM1602
INTERVAL = 1.0

$stdout.sync = true # so the readings still appear when piped to a file

sensor = Rgpio::ADT7410.new
lcd = Rgpio::ST7032.new(columns: COLUMNS)

sleep Rgpio::ADT7410::CONVERSION_TIME

# The label never changes, so write it once.
lcd.move_to(0, 0)
lcd.print("Temp".ljust(COLUMNS))

begin
  loop do
    celsius = sensor.temperature

    # Overwrite the value in place rather than clearing: a clear blanks the
    # panel for the width of the next transfer, which reads as a flicker once
    # a second. Padding to the full row erases the previous, longer value.
    lcd.move_to(0, 1)
    lcd.print(format("%.1f C", celsius).rjust(COLUMNS))

    puts format("%.2f degC", celsius)
    sleep INTERVAL
  end
rescue Interrupt
  puts "\nStopped."
ensure
  lcd.clear
  lcd.close
  sensor.close
end
