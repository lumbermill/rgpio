module Rgpio
  # Shared by the PWM-backed devices ({PWMOutputDevice}, {Servo}): turns the
  # `pwm:` option into a channel to drive the line with.
  #
  # A symbol means the device opens — and later closes — a channel of its own.
  # Anything else is a channel the caller owns and keeps, so that several devices
  # can share one, or a {HardwarePWM} already configured the way they want it.
  module PWMChannel
    private

    # @return [Array(Object, Boolean)] the channel, and whether it is ours to close
    def resolve_pwm(pwm, gpio:, frequency:, chip:, consumer:)
      return [pwm, false] unless pwm.is_a?(Symbol)

      case pwm
      when :software
        [SoftwarePWM.new(gpio, frequency: frequency, chip: chip, consumer: consumer), true]
      when :hardware
        [HardwarePWM.new(gpio: gpio).tap { |channel| channel.frequency = frequency }, true]
      else
        raise ArgumentError, "pwm must be :software, :hardware or a PWM channel, got #{pwm.inspect}"
      end
    end
  end
end
