#!/usr/bin/env ruby

# Tap the screen to drop a ruby: it falls from where you touched and piles up
# on the ones already there. A game of nothing, on a 2.8" ILI9341 + XPT2046.
#
# Wiring: as in examples/touch_paint.rb.
#
# Run:
#   ruby examples/ruby_stack.rb
#   ruby examples/ruby_stack.rb <six calibration numbers>   # skip calibrating
#
# The screen is used in landscape, turned 90 degrees to the left (ROTATION; 90
# turns it the other way). The calibration follows the rotation, so numbers
# printed by examples/touch_paint.rb, which runs upright, do not carry over.
#
# Touching the grey "Hello, rgpio!" strip at the top clears the pile, and so
# does a pile that reaches the strip. Ctrl-C to stop.
#
# The gem is drawn here from flat facets — it is not the Ruby logo artwork.

require_relative "../lib/rgpio"
require_relative "touch_calibration"

$stdout.sync = true

ROTATION = 270
BAR = 24
TITLE = "Hello, rgpio!".freeze
GRAVITY = 900.0 # px/s²
FRAME = 1.0 / 60

# One cut gem, 32x28 at scale 1: a crown of five facets over a pavilion of
# three, each a triangle in its own shade of red.
module Jewel
  TOP = [[8, 0], [16, 0], [24, 0]].freeze
  GIRDLE = [[0, 8], [11, 8], [21, 8], [32, 8]].freeze
  TIP = [16, 28].freeze
  FACETS = [
    [[TOP[0], GIRDLE[0], GIRDLE[1]], [220, 50, 60]],
    [[TOP[0], TOP[1], GIRDLE[1]], [245, 90, 95]],
    [[TOP[1], GIRDLE[1], GIRDLE[2]], [255, 150, 150]], # the table catches the light
    [[TOP[1], TOP[2], GIRDLE[2]], [235, 70, 80]],
    [[TOP[2], GIRDLE[2], GIRDLE[3]], [190, 20, 35]],
    [[GIRDLE[0], GIRDLE[1], TIP], [170, 10, 30]],
    [[GIRDLE[1], GIRDLE[2], TIP], [215, 30, 45]],
    [[GIRDLE[2], GIRDLE[3], TIP], [130, 0, 20]],
  ].freeze
  WIDTH = 32
  HEIGHT = 28

  # @return [Array(Integer, Integer, String)] width, height and RGB565 pixels
  #   on black, ready for ILI9341#blit
  def self.sprite(scale)
    w = (WIDTH * scale).round
    h = (HEIGHT * scale).round
    facets = FACETS.map { |points, rgb| [points.map { |x, y| [x * scale, y * scale] }, Rgpio::RGB565.from(rgb)] }
    pixels = Array.new(w * h, 0)
    h.times do |y|
      w.times do |x|
        px = x + 0.5
        py = y + 0.5
        hit = facets.find { |points, _| inside?(points, px, py) }
        pixels[(y * w) + x] = hit[1] if hit
      end
    end
    [w, h, pixels.pack("n*")]
  end

  def self.inside?((a, b, c), x, y)
    d1 = cross(a, b, x, y)
    d2 = cross(b, c, x, y)
    d3 = cross(c, a, x, y)
    !((d1.negative? || d2.negative? || d3.negative?) && (d1.positive? || d2.positive? || d3.positive?))
  end

  def self.cross((ax, ay), (bx, by), x, y)
    ((bx - ax) * (y - ay)) - ((by - ay) * (x - ax))
  end
end

# A gem on its way down. It lands on the highest thing under any of its columns.
Falling = Struct.new(:x, :y, :speed, :sprite) do
  def width = sprite[0]
  def height = sprite[1]
end

def clear(lcd, floor)
  floor.fill(lcd.height)
  lcd.fill(:black)
  lcd.fill_rect(0, 0, lcd.width, BAR, :gray)
  title_width, = lcd.text_size(TITLE, scale: 2)
  lcd.text((lcd.width - title_width) / 2, 4, TITLE, color: :red, bg: :gray, scale: 2)
end

chip = Rgpio::Chip.new
lcd = Rgpio::ILI9341.new(dc: 24, reset: 25, backlight: 18, chip: chip)
touch = Rgpio::XPT2046.new(irq: 17, chip: chip)

begin
  lcd.rotation = ROTATION
  touch.calibration = TouchCalibration.load_or_run(lcd, touch)

  sprites = [0.75, 1.0, 1.25, 1.5, 2.0].map { |scale| Jewel.sprite(scale) }
  floor = Array.new(lcd.width) # the top of the pile, per column
  clear(lcd, floor)
  puts "2) tap to drop rubies (the strip at the top clears; Ctrl-C to stop)"

  falling = []
  was_down = false
  dropped = 0
  last = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  loop do
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    dt = now - last
    last = now

    # A new press, not a held finger, drops one gem.
    x, y = touch.position
    down = !x.nil?
    if down && !was_down
      if y < BAR
        falling.clear
        clear(lcd, floor)
      else
        sprite = sprites.sample
        left = (x - (sprite[0] / 2)).clamp(0, lcd.width - sprite[0])
        top = [y - (sprite[1] / 2), BAR].max
        falling << Falling.new(left, top.to_f, 0.0, sprite)
        dropped += 1
        puts "   ruby #{dropped} at #{x}, #{y}"
      end
    end
    was_down = down

    falling.each do |jewel|
      old_y = jewel.y.round
      jewel.speed += GRAVITY * dt
      jewel.y += jewel.speed * dt
      landing = floor[jewel.x, jewel.width].min - jewel.height
      landed = jewel.y >= landing
      jewel.y = landing.to_f if landed
      new_y = jewel.y.round

      # Black out only the rows the jewel has left, then draw it lower down.
      lcd.fill_rect(jewel.x, old_y, jewel.width, new_y - old_y, :black) if new_y > old_y
      lcd.blit(jewel.x, new_y, jewel.width, jewel.height, jewel.sprite[2])
      next unless landed

      floor.fill(new_y, jewel.x, jewel.width)
      jewel.speed = nil
    end
    falling.reject! { |jewel| jewel.speed.nil? }

    if floor.min < BAR + 40
      puts "   the pile reached the top — clearing"
      sleep 1
      falling.clear
      clear(lcd, floor)
    end

    sleep FRAME
  end
rescue Interrupt
  nil
ensure
  touch.close
  lcd.close
  chip.close
end
