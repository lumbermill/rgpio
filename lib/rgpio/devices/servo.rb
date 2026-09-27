module Rgpio
  # An RC servo, positioned by the width of a pulse repeated every 20 ms.
  #
  #   servo = Rgpio::Servo.new(12)
  #   servo.max                  # one end of its travel
  #   servo.mid                  # centre
  #   servo.angle = 45           # or by angle
  #   servo.detach               # stop holding the position
  #   servo.close
  #
  # Pulse widths vary by servo: 1000..2000 us is the safe range every hobby
  # servo understands, and many reach further (500..2500 us). A servo driven past
  # its travel buzzes and heats up, so widen the range only as far as the part's
  # datasheet allows, and by measuring rather than by trusting.
  #
  # Accuracy: the default {SoftwarePWM} channel places the pulse within about
  # 6 us on an idle Pi 5, which is half a degree of travel; a busy machine can
  # push an occasional pulse 30-80 us out (see PLAN.md). `pwm: :hardware` on
  # GPIO12/13/18/19 removes that entirely, at the cost of a config.txt entry.
  class Servo
    include PWMChannel

    # The frame rate every hobby servo expects.
    DEFAULT_FREQUENCY = 50

    DEFAULT_MIN_PULSE_US = 1000
    DEFAULT_MAX_PULSE_US = 2000

    # @param gpio          [Integer] GPIO line offset (BCM numbering)
    # @param min_pulse_us  [Numeric] pulse width at value -1.0
    # @param max_pulse_us  [Numeric] pulse width at value +1.0
    # @param frequency     [Numeric] frame rate in Hz; ignored when `pwm:` is a
    #                      channel object, which the caller has already configured
    # @param min_angle     [Numeric] angle reported at value -1.0
    # @param max_angle     [Numeric] angle reported at value +1.0
    # @param initial_value [Float, nil] -1.0..1.0 to start there, nil to start
    #                      detached (no pulses, so the horn is free)
    # @param pwm           [:software, :hardware, Object] channel to drive with
    # @param chip          [Chip, nil] chip to share, or nil to open one
    # @param consumer      [String] name shown in the kernel's request list
    def initialize(gpio, min_pulse_us: DEFAULT_MIN_PULSE_US, max_pulse_us: DEFAULT_MAX_PULSE_US,
                   frequency: DEFAULT_FREQUENCY, min_angle: -90, max_angle: 90,
                   initial_value: 0.0, pwm: :software, chip: nil, consumer: "rgpio")
      raise ArgumentError, "max_pulse_us must exceed min_pulse_us" unless max_pulse_us > min_pulse_us

      @gpio = gpio
      @min_pulse_us = min_pulse_us.to_f
      @max_pulse_us = max_pulse_us.to_f
      @min_angle = min_angle.to_f
      @max_angle = max_angle.to_f
      @value = nil
      @closed = false
      @pwm, @owns_pwm = resolve_pwm(pwm, gpio: gpio, frequency: frequency, chip: chip, consumer: consumer)
      self.value = initial_value
      @pwm.enable
    end

    # @return [Integer] the GPIO line this servo is driven from
    attr_reader :gpio

    # @return [Object] the PWM channel behind this servo
    attr_reader :pwm

    # @return [Float, nil] -1.0..1.0, or nil when detached
    attr_reader :value

    # @return [Float] pulse width at value -1.0
    attr_reader :min_pulse_us

    # @return [Float] pulse width at value +1.0
    attr_reader :max_pulse_us

    # @param position [Float, nil] -1.0..1.0, or nil to detach
    def value=(position)
      raise Error, "Servo on GPIO#{@gpio} is closed" if @closed

      if position.nil?
        detach
      else
        unless position.is_a?(Numeric) && (-1.0..1.0).cover?(position)
          raise ArgumentError, "value must be in -1.0..1.0 or nil, got #{position.inspect}"
        end

        @value = position.to_f
        @pwm.pulse_width_us = @min_pulse_us + ((@max_pulse_us - @min_pulse_us) * ((@value + 1.0) / 2.0))
      end
    end

    def min
      self.value = -1.0
    end

    def mid
      self.value = 0.0
    end

    def max
      self.value = 1.0
    end

    # @return [Float, nil] the current position in degrees, or nil when detached
    def angle
      return nil if @value.nil?

      @min_angle + ((@max_angle - @min_angle) * ((@value + 1.0) / 2.0))
    end

    # @param degrees [Numeric, nil] between min_angle and max_angle
    def angle=(degrees)
      if degrees.nil?
        detach
      else
        low, high = [@min_angle, @max_angle].minmax
        unless degrees.is_a?(Numeric) && (low..high).cover?(degrees)
          raise ArgumentError, "angle must be in #{low}..#{high} degrees or nil, got #{degrees.inspect}"
        end

        self.value = (((degrees - @min_angle) / (@max_angle - @min_angle)) * 2.0) - 1.0
      end
    end

    # @return [Float, nil] the pulse width currently being sent, or nil when detached
    def pulse_width_us
      @value.nil? ? nil : @pwm.pulse_width_us
    end

    # Drive a pulse width directly, for calibrating a servo's real travel.
    def pulse_width_us=(us)
      raise ArgumentError, "pulse width must be positive, got #{us}" unless us.is_a?(Numeric) && us.positive?

      @pwm.pulse_width_us = us
      # The position no longer follows from #value, so stop claiming it does.
      @value = nil
    end

    # Stop sending pulses. The servo stops holding its position and can be
    # turned by hand — and stops drawing current fighting a load.
    def detach
      @pwm.duty_cycle = 0.0
      @value = nil
    end

    # @return [Boolean] true while pulses are being sent
    def attached?
      !@value.nil?
    end

    # Stop the channel, and release it if this servo opened it.
    # Safe to call multiple times.
    def close
      return if @closed

      @closed = true
      @owns_pwm ? @pwm.close : @pwm.disable
    end

    def closed?
      @closed
    end
  end
end
