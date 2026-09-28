module Rgpio
  # A full-colour LED: three {PWMLED} channels behind one object.
  #
  #   led = Rgpio::RGBLED.new(red: 2, green: 3, blue: 4)
  #   led.color = :magenta
  #   led.color = [1.0, 0.4, 0.0]   # amber
  #   led.off
  #   led.close
  #
  # The default wiring is common cathode: each line sources current through its
  # own resistor and the common leg goes to GND. For a common-anode part, tie the
  # common leg to 3.3 V and pass `active_low: true`.
  #
  # Three software PWM channels means three generating threads, each spinning
  # briefly around its edges (see {SoftwarePWM}). At the default 100 Hz that is
  # some 16% of one core, and the threads occasionally collide, which shifts an
  # edge by microseconds — invisible in an LED's brightness.
  class RGBLED
    # Corners of the colour cube, for the common case of naming a colour.
    COLORS = {
      off: [0.0, 0.0, 0.0],
      red: [1.0, 0.0, 0.0],
      green: [0.0, 1.0, 0.0],
      blue: [0.0, 0.0, 1.0],
      yellow: [1.0, 1.0, 0.0],
      cyan: [0.0, 1.0, 1.0],
      magenta: [1.0, 0.0, 1.0],
      white: [1.0, 1.0, 1.0],
    }.freeze

    # @param red        [Integer] GPIO line of the red channel
    # @param green      [Integer] GPIO line of the green channel
    # @param blue       [Integer] GPIO line of the blue channel
    # @param frequency  [Numeric] Hz, for all three channels
    # @param active_low [Boolean] true for a common-anode LED
    # @param balance    [Array<Float>] per-channel scale, 0.0..1.0 each, applied
    #                   on top of every level asked for
    # @param pwm        [:software, :hardware, Hash] channel kind, or a
    #                   {red:, green:, blue:} hash of channels to borrow
    # @param chip       [Chip, nil] chip to share, or nil to open one
    # @param consumer   [String] name shown in the kernel's request list
    def initialize(red:, green:, blue:, frequency: PWMOutputDevice::DEFAULT_FREQUENCY,
                   active_low: false, balance: [1.0, 1.0, 1.0], pwm: :software, chip: nil, consumer: "rgpio")
      @owns_chip = chip.nil? && pwm == :software
      @chip = @owns_chip ? Chip.new : chip
      @closed = false
      @balance = validate_triple(balance, "balance")
      @color = [0.0, 0.0, 0.0]
      lines = { red: red, green: green, blue: blue }
      # One channel per colour: handing the same channel object to all three
      # would have them overwrite each other's duty cycle.
      channels = pwm.is_a?(Hash) ? pwm : {}
      @channels = lines.to_h do |colour, gpio|
        channel = PWMLED.new(gpio,
                             frequency: frequency, active_low: active_low,
                             pwm: channels.fetch(colour, pwm), chip: @chip, consumer: consumer)
        [colour, channel]
      end
    end

    # @return [Hash{Symbol=>PWMLED}] the three channels, by colour
    attr_reader :channels

    # The colour that was asked for, not the duty cycles it became — {#balance}
    # and `active_low` both sit between the two.
    # @return [Array<Float>] red, green, blue in 0.0..1.0
    attr_reader :color

    # @param value [Array<Float>, Symbol] an r,g,b triple, or a name from {COLORS}
    def color=(value)
      triple = value.is_a?(Symbol) ? named_color(value) : value
      unless triple.is_a?(Array) && triple.size == 3
        raise ArgumentError, "color must be a three-element array or one of #{COLORS.keys.inspect}, " \
                             "got #{value.inspect}"
      end

      @color = validate_triple(triple, "color")
      apply
    end

    # @return [Array<Float>] the per-channel scale in force
    attr_reader :balance

    # Re-scale the channels, keeping the colour that was asked for. Setting this
    # while white is showing is how the calibration example works.
    def balance=(triple)
      @balance = validate_triple(triple, "balance")
      apply
    end

    def red
      @color[0]
    end

    def green
      @color[1]
    end

    def blue
      @color[2]
    end

    def red=(level)
      self.color = [level, green, blue]
    end

    def green=(level)
      self.color = [red, level, blue]
    end

    def blue=(level)
      self.color = [red, green, level]
    end

    # Full brightness on all three channels, which is white.
    def on
      self.color = :white
    end

    def off
      self.color = :off
    end

    # Invert every channel, so a dimmed colour comes back as its complement.
    def toggle
      self.color = @color.map { |level| 1.0 - level }
    end

    # @return [Boolean] true when any channel is lit
    def on?
      @color.any?(&:positive?)
    end

    alias active? on?

    # Stop all three channels, and close the chip if this LED opened it.
    # Safe to call multiple times.
    def close
      return if @closed

      @closed = true
      @channels.each_value(&:close)
      @chip.close if @owns_chip
    end

    def closed?
      @closed
    end

    private

    # Push the requested colour out through the balance. The channels hold the
    # scaled levels; #color keeps reporting what was asked for.
    def apply
      @channels.values.each_with_index do |channel, i|
        channel.value = @color[i] * @balance[i]
      end
    end

    def validate_triple(triple, what)
      unless triple.is_a?(Array) && triple.size == 3 &&
             triple.all? { |v| v.is_a?(Numeric) && (0.0..1.0).cover?(v) }
        raise ArgumentError, "#{what} must be three numbers in 0.0..1.0, got #{triple.inspect}"
      end

      triple.map(&:to_f)
    end

    def named_color(name)
      COLORS.fetch(name) do
        raise ArgumentError, "unknown colour #{name.inspect}; known: #{COLORS.keys.inspect}"
      end
    end
  end
end
