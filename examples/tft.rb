#!/usr/bin/env ruby

# Draw on a 2.8" ILI9341 TFT with Rgpio::ILI9341: full-screen fills (timed),
# rectangles, text at several sizes, and the four rotations.
#
# Module: the common red-board 240x320 SPI TFT with an XPT2046 touch
# controller (pins VCC GND CS RESET DC SDI SCK LED SDO T_CLK T_CS T_DIN T_DO
# T_IRQ). This example uses the display half only; examples/touch_paint.rb
# adds the touch panel on the same bus.
#
# Wiring (SPI0 must be enabled: sudo raspi-config nonint do_spi 0):
#   VCC   -- 3.3 V  (pin 1)
#   GND   -- GND    (pin 6)
#   CS    -- GPIO8  (pin 24, CE0)
#   RESET -- GPIO25 (pin 22)
#   DC    -- GPIO24 (pin 18)
#   SDI   -- GPIO10 (pin 19, MOSI)
#   SCK   -- GPIO11 (pin 23, SCLK)
#   LED   -- GPIO18 (pin 12)
#   SDO   -- leave unconnected: nothing is read from the display, and on some
#            boards it does not let go of MISO, which corrupts touch readings
#
# Run:
#   ruby examples/tft.rb

require_relative "../lib/rgpio"

$stdout.sync = true

puts "0) init (reset + init sequence)"
lcd = Rgpio::ILI9341.new(dc: 24, reset: 25, backlight: 18)

begin
  puts "1) full-screen fills, each held for 2 s"
  %i[red green blue white black].each do |color|
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    lcd.fill(color)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    puts format("   fill %-5s %6.1f ms", color, elapsed * 1000)
    sleep 2
  end

  puts "2) rectangles and text, held for 3 s"

  lcd.fill_rect(10, 10, 100, 50, :red)
  lcd.fill_rect(130, 10, 100, 50, [0, 128, 255])
  lcd.text(10, 80, "Hello", color: :white, scale: 2)
  lcd.text(10, 110, "rgpio", color: :yellow, bg: :navy, scale: 3)
  lcd.text(0, 150, (32..126).map(&:chr).join.scan(/.{1,40}/).join("\n"), color: :cyan)
  sleep 3

  puts "3) rotations, each held for 2 s (red square = top-left)"
  [90, 180, 270, 0].each do |rotation|
    puts "   rotation #{rotation}"
    lcd.rotation = rotation
    lcd.fill(:black)
    lcd.fill_rect(0, 0, 40, 40, :red) # always the top-left corner
    lcd.text(50, 10, "rotation #{rotation}", scale: 2)
    lcd.text(50, 40, "#{lcd.width} x #{lcd.height}", color: :green, scale: 2)
    sleep 2
  end
  puts "4) done; closing"
ensure
  lcd.close
end
