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

sensor = Rgpio::ADT7410.new
lcd = Rgpio::ST7032.new(columns: COLUMNS)

sleep Rgpio::ADT7410::CONVERSION_TIME

begin
  loop do
    celsius = sensor.temperature
    lcd.clear
    lcd.print(format("Temp\n%5.1f C", celsius))
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
