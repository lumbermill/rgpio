module Rgpio
  # Base class for a device driven by one PWM channel ({PWMOutputDevice},
  # {Servo}): resolves `pwm:` into a channel (see {PWMChannel}), and on #close
  # releases a channel it opened or stops one it borrowed.
  class PWMDevice
    include PWMChannel

    # @param gpio      [Integer] GPIO line offset (BCM numbering)
    # @param frequency [Numeric] Hz for a channel this device opens
    # @param pwm       [:auto, :software, :hardware, Object] channel kind, or a
    #                  channel to borrow
    # @param chip      [Chip, nil] chip to share, or nil to open one
    # @param consumer  [String] name shown in the kernel's request list
    def initialize(gpio, frequency:, pwm:, chip:, consumer:)
      @gpio = gpio
      @closed = false
      @pwm, @owns_pwm = resolve_pwm(pwm, gpio: gpio, frequency: frequency, chip: chip, consumer: consumer)
    end

    # @return [Integer] the GPIO line this device drives
    attr_reader :gpio

    # @return [Object] the PWM channel behind this device
    attr_reader :pwm

    # Stop the channel, and release it if this device opened it.
    # Safe to call multiple times.
    def close
      return if @closed

      @closed = true
      @owns_pwm ? @pwm.close : @pwm.disable
    end

    def closed?
      @closed
    end

    private

    def assert_open!
      raise Error, "#{self.class} on GPIO#{@gpio} is closed" if @closed
    end
  end
end
