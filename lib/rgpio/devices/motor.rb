module Rgpio
  # A DC motor behind a two-input driver such as the DRV8835 or SN754410:
  # one line drives it forward, the other backward.
  #
  #   motor = Rgpio::Motor.new(forward: 2, backward: 14)
  #   motor.forward
  #   sleep 5
  #   motor.backward
  #   sleep 5
  #   motor.stop
  #   motor.close
  #
  # Speed control needs PWM on both lines and is not supported yet; the motor
  # runs at full speed in either direction.
  class Motor < Device
    # @param forward  [Integer] GPIO line that drives the motor forward
    # @param backward [Integer] GPIO line that drives the motor backward
    # @param chip     [Chip, nil] chip to share, or nil to open one
    # @param consumer [String] name shown in the kernel's request list
    def initialize(forward:, backward:, chip: nil, consumer: "rgpio")
      super(chip: chip)
      @forward = OutputDevice.new(forward, chip: @chip, consumer: consumer)
      @backward = OutputDevice.new(backward, chip: @chip, consumer: consumer)
    end

    # Both directions are dropped before one is raised, so the driver is never
    # asked to source and sink the same output at once.
    def forward
      @backward.off
      @forward.on
    end

    def backward
      @forward.off
      @backward.on
    end

    def stop
      @forward.off
      @backward.off
    end

    private

    def release_resources
      stop
      @forward.close
      @backward.close
    end
  end
end
