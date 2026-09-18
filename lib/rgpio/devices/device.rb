module Rgpio
  # Base class for the high-level device API (LED, Button, MotionSensor, Motor).
  #
  # A device either borrows a Chip given by the caller or opens its own. Only a
  # chip the device opened itself is closed by #close, so several devices can
  # share one chip handle:
  #
  #   chip  = Rgpio::Chip.new
  #   red   = Rgpio::LED.new(17, chip: chip)
  #   green = Rgpio::LED.new(27, chip: chip)
  class Device
    # @param chip [Chip, nil] chip to drive this device on; nil opens (and
    #             later closes) a chip of its own via auto-detection
    def initialize(chip: nil)
      @owns_chip = chip.nil?
      @chip = chip || Chip.new
      @closed = false
    end

    # @return [Chip] the chip this device is driven on
    attr_reader :chip

    # Release the device's lines, and the chip too if this device opened it.
    # Safe to call multiple times.
    def close
      return if @closed

      @closed = true
      release_resources
      @chip.close if @owns_chip
    end

    def closed?
      @closed
    end

    private

    def release_resources; end
  end
end
