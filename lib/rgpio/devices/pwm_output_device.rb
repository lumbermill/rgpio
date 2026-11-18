module Rgpio
  # A GPIO line driven by a PWM channel, so it has a level between off and on
  # rather than just the two.
  #
  # The channel is chosen from the pin (`pwm: :auto`): {HardwarePWM} on
  # GPIO12/13/18/19 once a dtoverlay routes the pin to the PWM peripheral,
  # {SoftwarePWM} on every other line, and on those four without the overlay
  # (with a one-time warning). See {PWMChannel}. Pass `pwm: :software` or
  # `pwm: :hardware` to force one, or a channel object to share one.
  class PWMOutputDevice < PWMDevice
    # Fast enough that an LED does not visibly flicker, and gpiozero's default.
    DEFAULT_FREQUENCY = 100

    # @param gpio          [Integer] GPIO line offset (BCM numbering)
    # @param frequency     [Numeric] Hz; ignored when `pwm:` is a channel object,
    #                      which the caller has already configured
    # @param initial_value [Float] 0.0..1.0, applied before the channel starts
    # @param active_low    [Boolean] when true, 1.0 drives the line low — the
    #                      wiring of a common-anode LED
    # @param pwm           [:auto, :software, :hardware, Object] channel to
    #                      drive the line with, or one to borrow
    # @param chip          [Chip, nil] chip to share, or nil to open one
    # @param consumer      [String] name shown in the kernel's request list
    def initialize(gpio, frequency: DEFAULT_FREQUENCY, initial_value: 0.0, active_low: false,
                   pwm: :auto, chip: nil, consumer: "rgpio")
      super(gpio, frequency: frequency, pwm: pwm, chip: chip, consumer: consumer)
      @active_low = active_low
      self.value = initial_value
      @pwm.enable
    end

    # @return [Float] current level, 0.0..1.0
    attr_reader :value

    # @param ratio [Float] 0.0 = off, 1.0 = full on
    def value=(ratio)
      assert_open!
      unless ratio.is_a?(Numeric) && (0.0..1.0).cover?(ratio)
        raise ArgumentError, "value must be in 0.0..1.0, got #{ratio.inspect}"
      end

      @value = ratio.to_f
      @pwm.duty_cycle = @active_low ? 1.0 - @value : @value
    end

    def on
      self.value = 1.0
    end

    def off
      self.value = 0.0
    end

    # Invert the level, so a half-lit LED stays half-lit the other way about.
    def toggle
      self.value = 1.0 - @value
    end

    # @return [Boolean] true when the line is not fully off
    def on?
      @value.positive?
    end

    alias active? on?

    # @return [Numeric] the channel's frequency in Hz
    def frequency
      @pwm.frequency
    end

    def frequency=(hz)
      @pwm.frequency = hz
    end
  end

  # An LED whose brightness can be set, not just its state.
  #
  #   led = Rgpio::PWMLED.new(4)
  #   led.value = 0.25           # a quarter bright
  #   10.times { |i| led.value = i / 9.0; sleep 0.1 }
  #   led.close
  class PWMLED < PWMOutputDevice
    alias brightness value
    alias brightness= value=
  end
end
