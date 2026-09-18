module Rgpio
  # A single GPIO line driven as an output.
  #
  #   out = Rgpio::OutputDevice.new(17)
  #   out.on
  #   out.off
  #   out.close
  class OutputDevice < Device
    # @param gpio          [Integer] GPIO line offset (BCM numbering)
    # @param active_low    [Boolean] when true, #on drives the line low
    # @param initial_value [Boolean] level to drive as soon as the line is claimed
    # @param chip          [Chip, nil] chip to share, or nil to open one
    # @param consumer      [String] name shown in the kernel's request list
    def initialize(gpio, active_low: false, initial_value: false, chip: nil, consumer: "rgpio")
      super(chip: chip)
      @gpio = gpio
      @request = @chip.request_lines(
        offsets: [gpio],
        direction: :output,
        active_low: active_low,
        initial_value: initial_value ? :active : :inactive,
        consumer: consumer
      )
    end

    # @return [Integer] the GPIO line offset this device drives
    attr_reader :gpio

    def on
      self.value = true
    end

    def off
      self.value = false
    end

    def toggle
      self.value = !value
    end

    # @return [Boolean] true when the line is at its active level
    def value
      @request.get_value(@gpio) == :active
    end

    def value=(level)
      @request.set_value(@gpio, level ? :active : :inactive)
    end

    alias on? value

    private

    def release_resources
      @request.release
    end
  end

  # An LED on a GPIO line.
  #
  #   led = Rgpio::LED.new(4)
  #   5.times { led.on; sleep 1; led.off; sleep 1 }
  #   led.close
  class LED < OutputDevice
  end
end
