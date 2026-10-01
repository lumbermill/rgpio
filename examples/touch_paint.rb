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
#
# Touch the centre of each cross as it appears. The calibration is printed so
# it can be passed as `calibration: [...]` in a script of your own. Then draw;
# touching the grey strip at the top clears the screen. Ctrl-C to stop.

require_relative "../lib/rgpio"

MARGIN = 20
BAR = 24

def cross(lcd, x, y, color)
  lcd.fill_rect(x - 10, y, 21, 1, color)
  lcd.fill_rect(x, y - 10, 1, 21, color)
end

# Wait for a press, average the raw readings while it is held, then wait for
# the release.
def raw_touch(touch)
  sleep 0.01 until touch.touched?
  samples = []
  while (sample = touch.raw)[2] >= touch.threshold
    samples << sample
    sleep 0.01
  end
  sleep 0.2
  samples = samples.drop(2) if samples.size > 4 # the first readings are still landing
  [samples.sum { |s| s[0] } / samples.size, samples.sum { |s| s[1] } / samples.size]
end

def calibrate(lcd, touch)
  w = lcd.width
  h = lcd.height
  targets = [[MARGIN, MARGIN], [w - MARGIN, MARGIN], [w - MARGIN, h - MARGIN], [MARGIN, h - MARGIN], [w / 2, h / 2]]
  raw = targets.map do |x, y|
    lcd.fill(:black)
    lcd.text(30, (h / 2) + 30, "Touch the cross", scale: 2)
    cross(lcd, x, y, :white)
    raw_touch(touch)
  end
  Rgpio::XPT2046.calibration_from(targets, raw)
end

def clear(lcd)
  lcd.fill(:black)
  lcd.fill_rect(0, 0, lcd.width, BAR, :gray)
  lcd.text(4, 4, "clear", color: :black, bg: :gray, scale: 2)
end

chip = Rgpio::Chip.new
lcd = Rgpio::ILI9341.new(dc: 24, reset: 25, backlight: 18, chip: chip)
touch = Rgpio::XPT2046.new(irq: 17, chip: chip)

begin
  touch.calibration = calibrate(lcd, touch)
  puts "calibration: #{touch.calibration.map { |c| c.round(5) }.inspect}"
  clear(lcd)

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
