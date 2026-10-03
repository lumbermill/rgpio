# Touch calibration shared by examples/touch_paint.rb and examples/ruby_stack.rb.
#
# Six numbers on the command line are used as the calibration as they are;
# otherwise a cross is shown at each corner and the centre in turn, and the
# fitted calibration is printed together with the command line that reuses it.
module TouchCalibration
  MARGIN = 20

  module_function

  # @return [Array<Float>] the calibration to give XPT2046#calibration=
  def load_or_run(lcd, touch, args = ARGV)
    unless args.empty?
      raise ArgumentError, "a calibration is six numbers, got #{args.size}" unless args.size == 6

      return args.map { Float(_1) }
    end

    puts "1) calibration: touch the centre of each cross"
    calibration = run(lcd, touch)
    numbers = calibration.map { |c| c.round(5) }
    puts "calibration: #{numbers.inspect}"
    puts "   skip this next time: ruby #{$PROGRAM_NAME} #{numbers.join(" ")}"
    calibration
  end

  def run(lcd, touch)
    w = lcd.width
    h = lcd.height
    targets = [[MARGIN, MARGIN], [w - MARGIN, MARGIN], [w - MARGIN, h - MARGIN], [MARGIN, h - MARGIN], [w / 2, h / 2]]
    raw = targets.each_with_index.map do |(x, y), i|
      puts "   cross #{i + 1}/#{targets.size} at #{x}, #{y}"
      lcd.fill(:black)
      lcd.text(30, (h / 2) + 30, "Touch the cross", scale: 2)
      cross(lcd, x, y, :white)
      raw_touch(touch)
    end
    Rgpio::XPT2046.calibration_from(targets, raw)
  end

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
    return raw_touch(touch) if samples.empty? # a tap too brief to read

    samples = samples.drop(2) if samples.size > 4 # the first readings are still landing
    [samples.sum { |s| s[0] } / samples.size, samples.sum { |s| s[1] } / samples.size]
  end
end
