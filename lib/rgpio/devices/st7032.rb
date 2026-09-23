module Rgpio
  # A character LCD driven by a Sitronix ST7032 controller over I2C — the
  # module in the Akizuki AQM0802 (8x2) and AQM1602 (16x2) boards.
  #
  #   lcd = Rgpio::ST7032.new
  #   lcd.message = "Hello\nrgpio"
  #   lcd.close
  #
  # Every transfer is a control byte followed by payload: 0x00 for an
  # instruction, 0x40 for display data.
  #
  # The boost converter and contrast settings below are the 3.3 V values. The
  # controller has no way to read the panel back, so a blank display with the
  # backlight on is almost always contrast: raise or lower it with #contrast=.
  class ST7032
    DEFAULT_ADDRESS = 0x3e

    # Control byte: instruction vs. display data.
    CONTROL_COMMAND = 0x00
    CONTROL_DATA = 0x40

    # Instruction set (IS = 0).
    CMD_CLEAR = 0x01
    CMD_HOME = 0x02
    CMD_ENTRY_MODE = 0x06        # increment cursor, no display shift
    CMD_DISPLAY_OFF = 0x08
    CMD_DISPLAY_ON = 0x0c        # display on, cursor off, blink off
    CMD_FUNCTION_SET = 0x38      # 8-bit bus, 2 lines, normal instructions
    CMD_SET_DDRAM = 0x80

    # Extended instruction set (IS = 1).
    CMD_FUNCTION_SET_EXT = 0x39
    CMD_OSC_FREQUENCY = 0x14     # 1/5 bias, 183 kHz internal oscillator
    CMD_FOLLOWER_ON = 0x6c       # follower on, amplifier ratio 4
    CMD_CONTRAST_LOW = 0x70      # | C3..C0
    CMD_POWER_CONTRAST_HIGH = 0x50 # | Ion << 3 | Bon << 2 | C5..C4
    BOOSTER_ON = 0x04

    # Contrast is 6 bits split across two instructions. 0x20 suits 3.3 V panels.
    CONTRAST_RANGE = (0..0x3f)
    DEFAULT_CONTRAST = 0x20

    # DDRAM address of each row's first column.
    ROW_OFFSETS = [0x00, 0x40].freeze

    # Instructions need 26.3 us to execute; clear and home need 1.08 ms. The
    # follower circuit needs time to stabilise before the panel is driven.
    EXECUTION_DELAY = 0.000_05
    CLEAR_DELAY = 0.002
    POWER_DELAY = 0.2

    # Open a display, yielding it and closing it afterwards when a block is given.
    # @return [ST7032, Object] the display, or the block's value
    def self.open(**)
      lcd = new(**)
      return lcd unless block_given?

      begin
        yield lcd
      ensure
        lcd.close
      end
    end

    # @param address  [Integer] 7-bit address; the ST7032 is fixed at 0x3e
    # @param bus      [Integer] i2c-dev bus number
    # @param columns  [Integer] characters per row (8 for AQM0802, 16 for AQM1602)
    # @param rows     [Integer] number of rows
    # @param contrast [Integer] 0..63
    # @param booster  [Boolean] enable the internal boost converter (needed at 3.3 V)
    # @param i2c      [I2C, nil] an open device to share, or nil to open one
    def initialize(address: DEFAULT_ADDRESS, bus: I2C::DEFAULT_BUS, columns: 8, rows: 2,
                   contrast: DEFAULT_CONTRAST, booster: true, i2c: nil)
      raise ArgumentError, "rows must be 1 or 2, got #{rows}" unless (1..ROW_OFFSETS.size).cover?(rows)

      @owns_i2c = i2c.nil?
      @i2c = i2c || I2C.new(address: address, bus: bus)
      @columns = columns
      @rows = rows
      @contrast = validate_contrast(contrast)
      @booster = booster
      @closed = false
      reset
    end

    # @return [I2C] the bus device this display is written through
    attr_reader :i2c

    # @return [Integer] characters per row
    attr_reader :columns

    # @return [Integer] number of rows
    attr_reader :rows

    # @return [Integer] current contrast setting, 0..63
    attr_reader :contrast

    # Run the power-on initialisation sequence. Called by .new; call it again
    # after the panel has been power-cycled behind the driver's back.
    def reset
      command(CMD_FUNCTION_SET)
      command(CMD_FUNCTION_SET_EXT)
      command(CMD_OSC_FREQUENCY)
      apply_contrast
      command(CMD_FOLLOWER_ON)
      sleep POWER_DELAY
      command(CMD_FUNCTION_SET)
      command(CMD_DISPLAY_ON)
      command(CMD_ENTRY_MODE)
      clear
      self
    end

    # Blank the display and return the cursor to the top left.
    def clear
      command(CMD_CLEAR, delay: CLEAR_DELAY)
      @col = 0
      @row = 0
      self
    end

    # Return the cursor to the top left, leaving the contents alone.
    def home
      command(CMD_HOME, delay: CLEAR_DELAY)
      @col = 0
      @row = 0
      self
    end

    # Move the cursor. Out-of-range positions raise rather than wrapping, since
    # the DDRAM address they would land on is rarely what the caller meant.
    # @param col [Integer] 0-based column
    # @param row [Integer] 0-based row
    def move_to(col, row = 0)
      raise ArgumentError, "column must be in 0...#{@columns}, got #{col}" unless (0...@columns).cover?(col)
      raise ArgumentError, "row must be in 0...#{@rows}, got #{row}" unless (0...@rows).cover?(row)

      command(CMD_SET_DDRAM | (ROW_OFFSETS[row] + col))
      @col = col
      @row = row
      self
    end

    alias set_cursor move_to

    # Write text at the cursor. A newline moves to the start of the next row;
    # text that would run past the last column of a row is dropped, as the
    # controller would otherwise scatter it into the other row's DDRAM.
    def print(text)
      text.to_s.split("\n", -1).each_with_index do |line, index|
        if index.positive?
          break if @row + 1 >= @rows

          move_to(0, @row + 1)
        end
        write_data(line)
      end
      self
    end

    # Replace the whole display with +text+ (clear, then print).
    def message=(text)
      clear
      print(text)
    end

    def display_on
      command(CMD_DISPLAY_ON)
      self
    end

    def display_off
      command(CMD_DISPLAY_OFF)
      self
    end

    # @param value [Integer] 0..63
    def contrast=(value)
      @contrast = validate_contrast(value)
      command(CMD_FUNCTION_SET_EXT)
      apply_contrast
      command(CMD_FUNCTION_SET)
      value
    end

    # Send a raw instruction byte.
    def command(byte, delay: EXECUTION_DELAY)
      @i2c.write(CONTROL_COMMAND, byte)
      sleep delay
      self
    end

    # Send display data (a String is taken as its bytes — the ST7032 character
    # ROM is ASCII in 0x20..0x7d, so non-ASCII text needs a custom mapping).
    def write_data(text)
      bytes = text.is_a?(String) ? text.b.bytes : Array(text)
      bytes = bytes.first(@columns - @col)
      return self if bytes.empty?

      @i2c.write(CONTROL_DATA, bytes)
      @col += bytes.size
      sleep EXECUTION_DELAY
      self
    end

    # Close the bus device, but only if this display opened it. The panel keeps
    # showing whatever was written last.
    def close
      return if @closed

      @closed = true
      @i2c.close if @owns_i2c
    end

    def closed?
      @closed
    end

    private

    def validate_contrast(value)
      raise ArgumentError, "contrast must be in 0..63, got #{value}" unless CONTRAST_RANGE.cover?(value)

      value
    end

    # Both halves of the contrast value live in the extended instruction set,
    # so the caller must have selected it first.
    def apply_contrast
      command(CMD_CONTRAST_LOW | (@contrast & 0x0f))
      command(CMD_POWER_CONTRAST_HIGH | (@booster ? BOOSTER_ON : 0) | ((@contrast >> 4) & 0x03))
    end
  end
end
