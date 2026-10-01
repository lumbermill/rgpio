require "monitor"

module Rgpio
  # A 240x320 colour TFT driven by an Ilitek ILI9341 over SPI — the 2.4"/2.8"
  # modules with an XPT2046 touch controller on the same board.
  #
  #   lcd = Rgpio::ILI9341.new(dc: 24, reset: 25, backlight: 18)
  #   lcd.fill(:black)
  #   lcd.fill_rect(10, 10, 100, 50, :red)
  #   lcd.text(10, 80, "Temp 23.5C", color: :white, scale: 2)
  #   lcd.close
  #
  # The controller tells a command byte from its parameters by the D/C line —
  # low for a command, high for data — so D/C (and RESET, if wired) are GPIO
  # outputs alongside the SPI bus. Pixels are 16-bit RGB565, high byte first.
  #
  # Colours are anything {RGB565.from} takes: a name such as :red, an
  # [r, g, b] triple of 0..255, or an RGB565 Integer. Drawing is clipped to the
  # screen.
  #
  # Text is drawn by {Font5x7::Drawing#text}.
  #
  # Every drawing call is one command sequence (window, then pixel data) held
  # under a lock, so a touch callback on another thread can draw too.
  class ILI9341
    include Font5x7::Drawing

    NATIVE_WIDTH = 240
    NATIVE_HEIGHT = 320

    DEFAULT_SPEED_HZ = 32_000_000

    # Command set (datasheet section 8).
    CMD_SWRESET = 0x01
    CMD_SLPOUT = 0x11
    CMD_INVOFF = 0x20
    CMD_INVON = 0x21
    CMD_GAMMASET = 0x26
    CMD_DISPON = 0x29
    CMD_CASET = 0x2a
    CMD_PASET = 0x2b
    CMD_RAMWR = 0x2c
    CMD_MADCTL = 0x36
    CMD_PIXFMT = 0x3a
    CMD_FRMCTR1 = 0xb1
    CMD_DFUNCTR = 0xb6
    CMD_PWCTR1 = 0xc0
    CMD_PWCTR2 = 0xc1
    CMD_VMCTR1 = 0xc5
    CMD_VMCTR2 = 0xc7
    CMD_GMCTRP1 = 0xe0
    CMD_GMCTRN1 = 0xe1

    # Power, VCOM, frame rate and gamma for the common 2.4"/2.8" panels. These
    # are the values the widely used Adafruit driver ships.
    INIT_SEQUENCE = [
      [CMD_PWCTR1, 0x23],
      [CMD_PWCTR2, 0x10],
      [CMD_VMCTR1, 0x3e, 0x28],
      [CMD_VMCTR2, 0x86],
      [CMD_PIXFMT, 0x55],                       # 16 bits per pixel
      [CMD_FRMCTR1, 0x00, 0x18],                # 79 Hz
      [CMD_DFUNCTR, 0x08, 0x82, 0x27],
      [CMD_GAMMASET, 0x01],
      [CMD_GMCTRP1, 0x0f, 0x31, 0x2b, 0x0c, 0x0e, 0x08, 0x4e, 0xf1,
       0x37, 0x07, 0x10, 0x03, 0x0e, 0x09, 0x00,],
      [CMD_GMCTRN1, 0x00, 0x0e, 0x14, 0x03, 0x11, 0x07, 0x31, 0xc1,
       0x48, 0x08, 0x0f, 0x0c, 0x31, 0x36, 0x0f,],
    ].freeze

    # MADCTL bits: row/column order and exchange, and the panel's colour order.
    MADCTL_MY = 0x80
    MADCTL_MX = 0x40
    MADCTL_MV = 0x20
    MADCTL_BGR = 0x08

    # Rotation in degrees => MADCTL. 0 is portrait with the FPC at the bottom.
    ROTATIONS = {
      0 => MADCTL_MX,
      90 => MADCTL_MV,
      180 => MADCTL_MY,
      270 => MADCTL_MX | MADCTL_MY | MADCTL_MV,
    }.freeze

    # Reset pulse, and the waits the datasheet asks for after reset and
    # sleep-out before the next command.
    RESET_PULSE = 0.01
    RESET_DELAY = 0.12
    SLEEP_OUT_DELAY = 0.12

    # Open a display, yielding it and closing it afterwards when a block is given.
    # @return [ILI9341, Object] the display, or the block's value
    def self.open(**)
      lcd = new(**)
      return lcd unless block_given?

      begin
        yield lcd
      ensure
        lcd.close
      end
    end

    # @param dc            [Integer] GPIO line wired to D/C (sometimes DC/RS)
    # @param reset         [Integer, nil] GPIO line wired to RESET, or nil when
    #                      it is tied high; a software reset is sent either way
    # @param backlight     [Integer, nil] GPIO line wired to LED, or nil when it
    #                      is tied to 3.3 V
    # @param backlight_pwm [Boolean] drive the backlight with SoftwarePWM so
    #                      #backlight= takes a level, not just on/off
    # @param rotation      [Integer] 0, 90, 180 or 270
    # @param bgr           [Boolean] the panel's colour order; true for nearly
    #                      every module, false if red and blue come out swapped
    # @param bus           [Integer] spidev bus number
    # @param device        [Integer] chip-select index
    # @param speed_hz      [Integer] clock rate
    # @param spi           [SPI, nil] an open bus device to share, or nil to open one
    # @param chip          [Chip, nil] chip for the GPIO lines, or nil to open one
    # @param consumer      [String] name shown in the kernel's request list
    def initialize(dc:, reset: nil, backlight: nil, backlight_pwm: false, rotation: 0, bgr: true,
                   bus: 0, device: 0, speed_hz: DEFAULT_SPEED_HZ, spi: nil, chip: nil, consumer: "rgpio")
      validate_rotation(rotation)
      @bgr = bgr
      @lock = Monitor.new
      @closed = false
      @owns_spi = spi.nil?
      @spi = spi || SPI.new(bus: bus, device: device, speed_hz: speed_hz, mode: 0)
      @owns_chip = chip.nil?
      @chip = chip || Chip.new
      @dc = dc
      @dc_request = @chip.request_lines(offsets: [dc], direction: :output, initial_value: :inactive,
                                        consumer: consumer)
      @dc_level = :inactive
      @reset = reset
      @reset_request = reset && @chip.request_lines(offsets: [reset], direction: :output,
                                                    initial_value: :active, consumer: consumer)
      @backlight = backlight && open_backlight(backlight, backlight_pwm, consumer)
      @rotation = rotation
      reset!
      self.backlight = true if @backlight
    end

    # @return [SPI] the bus device pixels go through
    attr_reader :spi

    # @return [Integer] 0, 90, 180 or 270
    attr_reader :rotation

    # @return [Integer] screen width at the current rotation
    def width
      (@rotation % 180).zero? ? NATIVE_WIDTH : NATIVE_HEIGHT
    end

    # @return [Integer] screen height at the current rotation
    def height
      (@rotation % 180).zero? ? NATIVE_HEIGHT : NATIVE_WIDTH
    end

    # Reset the controller (by the RESET line when wired, and by command) and
    # bring it up again. The screen content is lost.
    def reset!
      synchronize do
        if @reset_request
          @reset_request.set_value(@reset, :inactive)
          wait(RESET_PULSE)
          @reset_request.set_value(@reset, :active)
        end
        command(CMD_SWRESET)
        wait(RESET_DELAY)
        INIT_SEQUENCE.each { |cmd, *params| command(cmd, *params) }
        command(CMD_MADCTL, madctl)
        command(CMD_SLPOUT)
        wait(SLEEP_OUT_DELAY)
        command(CMD_DISPON)
      end
      self
    end

    # Turn the drawing coordinates. What is already on screen stays where it
    # is; only what is drawn next follows the new orientation.
    def rotation=(degrees)
      validate_rotation(degrees)
      synchronize do
        @rotation = degrees
        command(CMD_MADCTL, madctl)
      end
    end

    # Swap every colour for its complement — some panels sold as ILI9341 need
    # this to show colours the right way round.
    def invert=(on)
      synchronize { command(on ? CMD_INVON : CMD_INVOFF) }
    end

    # @param level [Boolean, Float] on/off, or 0.0..1.0 with backlight_pwm: true
    def backlight=(level)
      raise Error, "no backlight line was given to #{self.class}" unless @backlight

      if @backlight.is_a?(PWMOutputDevice)
        @backlight.value = { true => 1.0, false => 0.0 }.fetch(level, level)
      elsif [true, false].include?(level)
        @backlight.value = level
      else
        raise ArgumentError, "a backlight level needs backlight_pwm: true; use true or false"
      end
    end

    # Fill the whole screen.
    def fill(color)
      fill_rect(0, 0, width, height, color)
    end

    # Fill a rectangle; the part off screen is skipped.
    def fill_rect(x, y, w, h, color)
      x0, y0, x1, y1 = clip(x, y, w, h)
      return self unless x0

      pixel = [RGB565.from(color)].pack("n")
      synchronize do
        set_window(x0, y0, x1, y1)
        write_pixels(pixel * ((x1 - x0 + 1) * (y1 - y0 + 1)))
      end
      self
    end

    def pixel(x, y, color)
      fill_rect(x, y, 1, 1, color)
    end

    # Copy a block of raw RGB565 pixels (two bytes each, high byte first, row by
    # row) to the screen. The part off screen is skipped.
    # @param data [String] w * h * 2 bytes
    def blit(x, y, w, h, data)
      data = data.b
      unless data.bytesize == w * h * 2
        raise ArgumentError, "blit of #{w}x#{h} needs #{w * h * 2} bytes, got #{data.bytesize}"
      end

      x0, y0, x1, y1 = clip(x, y, w, h)
      return self unless x0

      row_bytes = (x1 - x0 + 1) * 2
      visible = (y0..y1).map { |row| data.byteslice((((row - y) * w) + (x0 - x)) * 2, row_bytes) }.join
      synchronize do
        set_window(x0, y0, x1, y1)
        write_pixels(visible)
      end
      self
    end

    # Release the GPIO lines, and the bus and chip if this display opened them.
    # The panel keeps showing its last picture while it has power.
    def close
      return if @closed

      @closed = true
      @backlight&.close
      @reset_request&.release
      @dc_request.release
      @spi.close if @owns_spi
      @chip.close if @owns_chip
    end

    def closed?
      @closed
    end

    private

    def synchronize(&)
      raise Error, "#{self.class} is closed" if @closed

      @lock.synchronize(&)
    end

    def validate_rotation(degrees)
      return if ROTATIONS.key?(degrees)

      raise ArgumentError, "rotation must be one of #{ROTATIONS.keys.join(", ")}, got #{degrees.inspect}"
    end

    def open_backlight(gpio, pwm, consumer)
      pwm ? PWMLED.new(gpio, chip: @chip, consumer: consumer) : LED.new(gpio, chip: @chip, consumer: consumer)
    end

    def madctl
      ROTATIONS.fetch(@rotation) | (@bgr ? MADCTL_BGR : 0)
    end

    # @return [Array(Integer, Integer, Integer, Integer), nil] the visible
    #   corners x0, y0, x1, y1 (inclusive), or nil when nothing is visible
    def clip(x, y, w, h)
      x0 = [x, 0].max
      y0 = [y, 0].max
      x1 = [x + w, width].min - 1
      y1 = [y + h, height].min - 1
      return nil if x1 < x0 || y1 < y0

      [x0, y0, x1, y1]
    end

    def set_window(x0, y0, x1, y1)
      command(CMD_CASET, x0 >> 8, x0 & 0xff, x1 >> 8, x1 & 0xff)
      command(CMD_PASET, y0 >> 8, y0 & 0xff, y1 >> 8, y1 & 0xff)
      command(CMD_RAMWR)
    end

    def command(cmd, *params)
      dc(:inactive)
      @spi.write(cmd)
      return if params.empty?

      dc(:active)
      @spi.write(*params)
    end

    def write_pixels(data)
      dc(:active)
      @spi.send_bytes(data)
    end

    # D/C only changes between a command and its data, so skip the ioctl when
    # it is already where it needs to be.
    def dc(level)
      return if @dc_level == level

      @dc_request.set_value(@dc, level)
      @dc_level = level
    end

    def wait(seconds)
      sleep(seconds)
    end
  end
end
