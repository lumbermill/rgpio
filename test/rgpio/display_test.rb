require_relative "../test_helper"
require "rgpio"

# Hardware-free tests for the ILI9341 display, the XPT2046 touch controller and
# SPI#send_bytes. The fakes write into one shared log, so the order of D/C
# changes and bus traffic — which is what the controller actually sees — can be
# replayed as a list of commands with their parameters.
class DisplayTest < Minitest::Test
  # The ILI9341's reset and sleep-out waits add up to a quarter second per
  # display; they are timing, not behaviour, so the tests skip them.
  module NoWait
    private

    def wait(_seconds); end
  end
  Rgpio::ILI9341.prepend(NoWait)

  class FakeChip
    attr_reader :requests, :closed

    def initialize(log)
      @log = log
      @requests = []
      @closed = false
    end

    def request_lines(**options)
      request = FakeRequest.new(@log, options)
      @requests << request
      request
    end

    def close
      @closed = true
    end
  end

  class FakeRequest
    attr_reader :options, :released
    attr_accessor :event_batches

    def initialize(log, options)
      @log = log
      @options = options
      @values = {}
      @released = false
      @event_batches = []
    end

    def set_value(offset, value)
      @log << [:gpio, offset, value]
      @values[offset] = value
    end

    def get_value(offset)
      @values.fetch(offset, @options[:initial_value] || :inactive)
    end

    def read_edge_events(**)
      batch = @event_batches.shift
      sleep 0.001
      batch || []
    end

    def release
      @released = true
    end
  end

  class FakeSPI
    attr_reader :closed

    def initialize(log)
      @log = log
      @closed = false
    end

    def write(*bytes)
      @log << [:write, bytes.flatten]
      bytes.flatten.size
    end

    def send_bytes(data)
      @log << [:send, data.b]
      data.bytesize
    end

    def close
      @closed = true
    end
  end

  DC = 24
  RESET = 25
  BACKLIGHT = 18

  def setup
    @log = []
    @chip = FakeChip.new(@log)
    @spi = FakeSPI.new(@log)
  end

  # --- colours ----------------------------------------------------------- #

  def test_colours_accept_names_triples_and_rgb565
    assert_equal 0xf800, Rgpio::RGB565.from(:red)
    assert_equal 0x07e0, Rgpio::RGB565.from("green")
    assert_equal 0xffff, Rgpio::RGB565.from([255, 255, 255])
    assert_equal 0xfc00, Rgpio::RGB565.from([255, 128, 0])
    assert_equal 0x1234, Rgpio::RGB565.from(0x1234)
  end

  def test_bad_colours_are_rejected
    assert_raises(ArgumentError) { Rgpio::RGB565.from(:chartreuse) }
    assert_raises(ArgumentError) { Rgpio::RGB565.from([256, 0, 0]) }
    assert_raises(ArgumentError) { Rgpio::RGB565.from([1, 2]) }
    assert_raises(ArgumentError) { Rgpio::RGB565.from(0x10000) }
    assert_raises(ArgumentError) { Rgpio::RGB565.from(1.5) }
  end

  # --- ILI9341 bring-up -------------------------------------------------- #

  def test_reset_line_is_pulsed_before_the_software_reset
    new_lcd

    reset_events = @log.select { |e| e[0] == :gpio && e[1] == RESET }

    assert_equal [[:gpio, RESET, :inactive], [:gpio, RESET, :active]], reset_events
    assert_operator @log.index(reset_events.last), :<, @log.index([:write, [Rgpio::ILI9341::CMD_SWRESET]])
  end

  def test_init_sequence_sets_16_bit_pixels_and_ends_with_display_on
    new_lcd
    commands = replay

    assert_equal Rgpio::ILI9341::CMD_SWRESET, commands.first[0]
    assert_includes commands, [Rgpio::ILI9341::CMD_PIXFMT, [0x55]]
    assert_includes commands, [Rgpio::ILI9341::CMD_MADCTL, [0x48]]
    assert_equal [Rgpio::ILI9341::CMD_SLPOUT, []], commands[-2]
    assert_equal [Rgpio::ILI9341::CMD_DISPON, []], commands[-1]
  end

  def test_dc_and_reset_lines_start_at_their_idle_levels
    new_lcd
    dc, reset = @chip.requests

    assert_equal [DC], dc.options[:offsets]
    assert_equal :inactive, dc.options[:initial_value]
    assert_equal [RESET], reset.options[:offsets]
    assert_equal :active, reset.options[:initial_value], "RESET is active-low on the panel, so it must start high"
  end

  def test_backlight_is_switched_on_after_init_and_can_be_turned_off
    lcd = new_lcd(backlight: BACKLIGHT)
    backlight = @chip.requests.last

    assert_equal [BACKLIGHT], backlight.options[:offsets]
    assert_equal :active, backlight.get_value(BACKLIGHT)
    lcd.backlight = false

    assert_equal :inactive, backlight.get_value(BACKLIGHT)
    assert_raises(ArgumentError) { lcd.backlight = 0.5 }
  end

  def test_backlight_without_a_line_is_an_error
    assert_raises(Rgpio::Error) { new_lcd.backlight = true }
  end

  # --- geometry ---------------------------------------------------------- #

  def test_rotation_swaps_width_and_height_and_sets_madctl
    lcd = new_lcd

    assert_equal [240, 320], [lcd.width, lcd.height]
    @log.clear
    lcd.rotation = 90

    assert_equal [320, 240], [lcd.width, lcd.height]
    assert_equal [[Rgpio::ILI9341::CMD_MADCTL, [0x28]]], replay
    assert_raises(ArgumentError) { lcd.rotation = 45 }
  end

  def test_bgr_false_clears_the_colour_order_bit
    new_lcd(bgr: false, rotation: 270)

    assert_includes replay, [Rgpio::ILI9341::CMD_MADCTL, [0xe0]]
  end

  # --- drawing ----------------------------------------------------------- #

  def test_fill_rect_sets_the_window_and_streams_one_colour
    lcd = new_lcd
    @log.clear
    lcd.fill_rect(10, 20, 3, 2, :red)

    assert_equal [[Rgpio::ILI9341::CMD_CASET, [0, 10, 0, 12]],
                  [Rgpio::ILI9341::CMD_PASET, [0, 20, 0, 21]],
                  [Rgpio::ILI9341::CMD_RAMWR, ["\xf8\x00".b * 6]],], replay
  end

  def test_fill_covers_the_screen_with_wide_coordinates
    lcd = new_lcd(rotation: 90)
    @log.clear
    lcd.fill(:black)
    commands = replay

    assert_equal [0, 0, 0x01, 0x3f], commands[0][1], "x runs 0..319"
    assert_equal [0, 0, 0, 0xef], commands[1][1], "y runs 0..239"
    assert_equal 320 * 240 * 2, commands[2][1].first.bytesize
  end

  def test_drawing_is_clipped_to_the_screen
    lcd = new_lcd
    @log.clear
    lcd.fill_rect(-5, 315, 10, 10, :white)
    commands = replay

    assert_equal [0, 0, 0, 4], commands[0][1]
    assert_equal [0x01, 0x3b, 0x01, 0x3f], commands[1][1]
    assert_equal 5 * 5 * 2, commands[2][1].first.bytesize

    @log.clear
    lcd.fill_rect(240, 0, 10, 10, :white)
    lcd.pixel(-1, 0, :white)

    assert_empty @log, "nothing on screen means nothing on the bus"
  end

  def test_blit_sends_the_bytes_and_clips_rows
    lcd = new_lcd
    data = (0...(4 * 2)).map { |i| [i].pack("n") }.join # 4x2 pixels, values 0..7
    @log.clear
    lcd.blit(0, 0, 4, 2, data)

    assert_equal data, replay.last[1].first

    @log.clear
    lcd.blit(-2, 0, 4, 2, data)
    commands = replay

    assert_equal [0, 0, 0, 1], commands[0][1]
    assert_equal [2, 3, 6, 7].map { |v| [v].pack("n") }.join, commands.last[1].first
  end

  def test_blit_rejects_data_of_the_wrong_size
    assert_raises(ArgumentError) { new_lcd.blit(0, 0, 2, 2, "\x00" * 7) }
  end

  def test_opaque_text_is_one_block_per_line
    lcd = new_lcd
    @log.clear
    size = lcd.text(0, 0, "!", color: :white, bg: :black)
    commands = replay
    pixels = commands.last[1].first.unpack("n*")

    assert_equal [6, 8], size
    assert_equal [0, 0, 0, 5], commands[0][1]
    assert_equal [0, 0, 0, 7], commands[1][1]
    # "!" is column 2 lit on rows 0-4 and 6.
    column = Array.new(8) { |row| pixels[(row * 6) + 2] }

    assert_equal ([0xffff] * 5) + [0x0000, 0xffff, 0x0000], column
    assert_equal [0x0000] * 8, Array.new(8) { |row| pixels[row * 6] }
  end

  def test_scaled_text_and_newlines_report_their_size
    lcd = new_lcd

    assert_equal [36, 32], lcd.text(0, 0, "abc\nxy", bg: :black, scale: 2)
    assert_raises(ArgumentError) { lcd.text(0, 0, "a", scale: 0) }
  end

  def test_transparent_text_draws_strokes_only
    lcd = new_lcd
    @log.clear
    lcd.text(0, 0, "-", color: :white)
    commands = replay

    # "-" is one run, columns 0-4 of row 3.
    assert_equal [[0, 0, 0, 4], [0, 3, 0, 3]], commands.first(2).map(&:last)
    assert_equal 3, commands.size
  end

  def test_closed_display_refuses_to_draw_and_releases_its_lines
    lcd = new_lcd(backlight: BACKLIGHT)
    lcd.close

    assert(@chip.requests.all?(&:released))
    refute @spi.closed, "a bus passed in must not be closed by the display"
    refute @chip.closed
    assert_raises(Rgpio::Error) { lcd.fill(:black) }
  end

  # --- SPI#send_bytes ---------------------------------------------------- #

  class FakeIO
    attr_reader :messages

    def initialize
      @messages = []
    end

    def ioctl(request, message)
      @messages << [request, message.unpack("Q2L2")]
    end
  end

  def test_send_bytes_splits_at_the_spidev_buffer_size
    spi = Rgpio::SPI.allocate
    io = FakeIO.new
    spi.instance_variable_set(:@io, io)
    spi.instance_variable_set(:@speed_hz, 32_000_000)
    spi.instance_variable_set(:@bits_per_word, 8)
    chunk = Rgpio::SPI.max_transfer_size

    assert_equal (chunk * 2) + 10, spi.send_bytes("\x00" * ((chunk * 2) + 10))
    assert_equal([chunk, chunk, 10], io.messages.map { |_, fields| fields[2] })
    assert(io.messages.all? { |_, fields| fields[1].zero? }, "nothing is read back")
    assert(io.messages.all? { |_, fields| fields[3] == 32_000_000 })
  end

  # --- XPT2046 ----------------------------------------------------------- #

  # Answers each conversion command with the value set for that channel, and
  # can play back a list of pressures, one per Z1 reading.
  class FakeTouchSPI
    attr_accessor :readings, :pressures
    attr_reader :closed

    def initialize
      @readings = { Rgpio::XPT2046::CMD_X => 0, Rgpio::XPT2046::CMD_Y => 0,
                    Rgpio::XPT2046::CMD_Z1 => 0, Rgpio::XPT2046::CMD_Z2 => 4095, }
      @pressures = nil
      @closed = false
    end

    def transfer(bytes)
      cmd = bytes.first
      value = @readings.fetch(cmd)
      value = next_pressure if cmd == Rgpio::XPT2046::CMD_Z1 && @pressures
      value = value.shift || 0 if value.is_a?(Array)
      shifted = value << 3
      [0, shifted >> 8, shifted & 0xff]
    end

    def press(x, y, z1: 1000, z2: 4095)
      @readings.merge!(Rgpio::XPT2046::CMD_X => x, Rgpio::XPT2046::CMD_Y => y,
                       Rgpio::XPT2046::CMD_Z1 => z1, Rgpio::XPT2046::CMD_Z2 => z2)
    end

    def lift
      press(0, 0, z1: 0, z2: 4095)
    end

    def close
      @closed = true
    end

    private

    def next_pressure
      @pressures.size > 1 ? @pressures.shift : @pressures.first
    end
  end

  def test_raw_reads_x_y_and_pressure
    spi = FakeTouchSPI.new
    spi.press(1234, 3000, z1: 800, z2: 2500)
    touch = Rgpio::XPT2046.new(spi: spi)

    assert_equal [1234, 3000, 800 + 4095 - 2500], touch.raw
    assert_predicate touch, :touched?
    spi.lift

    refute_predicate touch, :touched?
    assert_nil touch.position
  end

  def test_raw_takes_the_median_and_drops_the_first_conversion
    spi = FakeTouchSPI.new
    spi.readings[Rgpio::XPT2046::CMD_X] = [4000, 100, 105, 3000, 102, 101]
    touch = Rgpio::XPT2046.new(spi: spi)

    assert_equal 102, touch.raw[0]
  end

  def test_position_is_raw_without_calibration_and_mapped_with_it
    spi = FakeTouchSPI.new
    spi.press(2000, 2000)
    touch = Rgpio::XPT2046.new(spi: spi)

    assert_equal [2000, 2000], touch.position
    touch.calibration = [0.0, -0.1, 300.0, 0.1, 0.0, -10.0]

    assert_equal [100, 190], touch.position
  end

  def test_calibration_from_recovers_a_swapped_and_mirrored_mapping
    screen = [[20, 20], [220, 20], [20, 300], [220, 300], [120, 160]]
    # The panel's x runs down the screen and its y runs right to left.
    raw = screen.map { |sx, sy| [(sy * 12) + 100, 3900 - (sx * 15)] }
    calibration = Rgpio::XPT2046.calibration_from(screen, raw)
    touch = Rgpio::XPT2046.new(spi: FakeTouchSPI.new, calibration: calibration)

    screen.zip(raw).each do |(sx, sy), (rx, ry)|
      assert_equal [sx, sy], touch.send(:to_screen, rx, ry)
    end
  end

  def test_calibration_needs_three_points_off_one_line
    assert_raises(ArgumentError) { Rgpio::XPT2046.calibration_from([[0, 0], [1, 1]], [[0, 0], [1, 1]]) }
    assert_raises(ArgumentError) do
      Rgpio::XPT2046.calibration_from([[0, 0], [1, 1], [2, 2]], [[0, 0], [10, 10], [20, 20]])
    end
    assert_raises(ArgumentError) { Rgpio::XPT2046.new(spi: FakeTouchSPI.new, calibration: [1, 2, 3]) }
  end

  def test_irq_line_is_a_pulled_up_falling_edge_input
    Rgpio::XPT2046.new(irq: 17, spi: FakeTouchSPI.new, chip: @chip)
    options = @chip.requests.first.options

    assert_equal [17], options[:offsets]
    assert_equal :falling, options[:edge]
    assert_equal :pull_up, options[:bias]
  end

  def test_touch_and_release_callbacks_follow_an_irq_edge
    spi = FakeTouchSPI.new
    touch = Rgpio::XPT2046.new(irq: 17, spi: spi, chip: @chip)
    irq = @chip.requests.first
    spi.press(150, 250)
    # Pressed for a few polls, then lifted.
    spi.pressures = ([1000] * 4) + [0]

    seen = Queue.new
    touch.when_touched  { |x, y| seen << [:touched, x, y] }
    touch.when_released { seen << [:released] }
    irq.event_batches = [[{ type: :falling, offset: 17, timestamp_ns: 1 }]]

    assert_equal [:touched, 150, 250], seen.pop
    assert_equal [:released], seen.pop
    touch.close

    assert_predicate irq, :released
  end

  def test_without_irq_the_watcher_polls_the_pressure
    spi = FakeTouchSPI.new
    spi.press(10, 20)
    spi.pressures = [0, 0, 1000, 1000, 0]
    touch = Rgpio::XPT2046.new(spi: spi)

    seen = Queue.new
    touch.when_touched { |x, y| seen << [x, y] }

    assert_equal [10, 20], seen.pop
    touch.close
  end

  def test_a_spurious_irq_edge_with_no_pressure_fires_nothing
    spi = FakeTouchSPI.new
    touch = Rgpio::XPT2046.new(irq: 17, spi: spi, chip: @chip)
    irq = @chip.requests.first
    calls = 0
    touch.when_touched { calls += 1 }
    irq.event_batches = [[{ type: :falling, offset: 17, timestamp_ns: 1 }]]
    sleep 0.05 until irq.event_batches.empty?
    sleep 0.05
    touch.close

    assert_equal 0, calls
  end

  private

  def new_lcd(**)
    Rgpio::ILI9341.new(dc: DC, reset: RESET, spi: @spi, chip: @chip, **)
  end

  # Turn the log into [command, [parameter bytes or pixel strings]] pairs by
  # following the D/C line, as the controller does.
  def replay
    dc = :inactive
    @log.each_with_object([]) do |(kind, *rest), commands|
      case kind
      when :gpio
        dc = rest[1] if rest[0] == DC
      when :write
        if dc == :inactive
          commands << [rest[0].first, []]
        else
          commands.last[1].concat(rest[0])
        end
      when :send
        commands.last[1] << rest[0]
      end
    end
  end
end
