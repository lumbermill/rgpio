#!/usr/bin/env ruby

# Calibrate the XPT2046 touch panel of a 2.8" ILI9341 module, then draw with a
# finger or stylus.
#
# Wiring: the display as in examples/tft.rb, plus the touch controller on the
# same SPI bus with chip select CE1:
#   T_CLK -- GPIO11 (pin 23, SCLK)  shared with SCK
#   T_DIN -- GPIO10 (pin 19, MOSI)  shared with SDI
#   T_DO  -- GPIO9  (pin 21, MISO)
#   T_CS  -- GPIO7  (pin 26, CE1)
#   T_IRQ -- GPIO17 (pin 11)
#
# Run:
#   ruby examples/touch_paint.rb
#   ruby examples/touch_paint.rb <six calibration numbers>   # skip calibrating
#
# Touch the centre of each cross as it appears. The calibration is printed so
# it can be passed on the command line next time, or as `calibration: [...]`
# in a script of your own. Then draw; touching the grey strip at the top clears
# the screen. Ctrl-C to stop.

require_relative "../lib/rgpio"
require_relative "touch_calibration"

$stdout.sync = true

BAR = 24

def clear(lcd)
  lcd.fill(:black)
  lcd.fill_rect(0, 0, lcd.width, BAR, :gray)
  lcd.text(4, 4, "clear", color: :black, bg: :gray, scale: 2)
end

chip = Rgpio::Chip.new
lcd = Rgpio::ILI9341.new(dc: 24, reset: 25, backlight: 18, chip: chip)
touch = Rgpio::XPT2046.new(irq: 17, chip: chip)

begin
  touch.calibration = TouchCalibration.load_or_run(lcd, touch)
  clear(lcd)
  puts "2) draw (grey strip at the top clears; Ctrl-C to stop)"

  # The callbacks run on the touch watcher thread; the loop below polls
  # #position on the main thread. Both can draw: the display serialises them.
  touch.when_touched  { |x, y| puts "touched at #{x}, #{y}" }
  touch.when_released { puts "released" }

  loop do
    x, y = touch.position
    if x.nil?
      sleep 0.01
    elsif y < BAR
      clear(lcd)
      sleep 0.3
    else
      lcd.fill_rect(x - 2, y - 2, 5, 5, :yellow)
    end
  end
rescue Interrupt
  nil
ensure
  touch.close
  lcd.close
  chip.close
end
