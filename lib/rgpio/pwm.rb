# frozen_string_literal: true

module Rgpio
  # Controls a hardware PWM channel via the Linux PWM sysfs interface
  # (/sys/class/pwm/pwmchipN/pwmM/).
  #
  # No FFI required — the kernel exposes the entire API through file I/O.
  #
  # Raspberry Pi 5 prerequisites
  # -----------------------------
  # The RP1 PWM peripheral must be enabled via dtoverlay in
  # /boot/firmware/config.txt before the chip appears in sysfs.
  # See README.md for the required overlay configuration.
  #
  # GPIO-to-PWM mapping on Pi 5 (RP1):
  #   GPIO12 → RP1 PWM chip, channel 0
  #   GPIO13 → RP1 PWM chip, channel 1
  #   GPIO18 → RP1 PWM chip, channel 2
  #   GPIO19 → RP1 PWM chip, channel 3
  #
  # Usage (block form — recommended):
  #   Rgpio::HardwarePWM.open(gpio: 18) do |pwm|
  #     pwm.frequency   = 50      # Hz  (standard servo)
  #     pwm.duty_cycle  = 0.075   # 7.5% = center position
  #     pwm.enable
  #     sleep 1
  #     pwm.pulse_width_us = 1000 # 1 ms = minimum position
  #   end
  #
  # Usage (manual):
  #   pwm = Rgpio::HardwarePWM.new(chip: 2, channel: 0)
  #   pwm.frequency  = 50
  #   pwm.duty_cycle = 0.075
  #   pwm.enable
  #   pwm.close   # disables + unexports
  class HardwarePWM
    PWM_SYSFS_ROOT = "/sys/class/pwm"

    # Device-tree model string, used to pick the board's PWM mapping.
    BOARD_MODEL_PATH = "/proc/device-tree/model"

    # GPIO offset → PWM channel, per board family. The pwmchip *number* is
    # resolved separately at runtime (see {PWM_CHIP_PROFILE}).
    #
    #   Pi 5 (RP1):     GPIO12/13/18/19 → channels 0/1/2/3 (one 4-channel chip)
    #   Pi 4 (BCM2711): GPIO12/18 → channel 0 (PWM0), GPIO13/19 → channel 1 (PWM1)
    GPIO_TO_PWM_CHANNEL = {
      pi5: { 12 => 0, 13 => 1, 18 => 2, 19 => 3 }.freeze,
      pi4: { 12 => 0, 13 => 1, 18 => 0, 19 => 1 }.freeze,
    }.freeze

    # Backwards-compatible alias for the Pi 5 mapping.
    GPIO_TO_PWM_CHANNEL_PI5 = GPIO_TO_PWM_CHANNEL[:pi5]

    # Hints for locating the header PWM chip in sysfs, per board family:
    #   address — substring of the chip's device symlink (the peripheral the
    #             40-pin header PWM pins route to)
    #   npwm    — channel count of that chip
    # Pi 5 (RP1 PWM0 at 1f00098000, 4 channels) is verified. Pi 4 (BCM2711 PWM0
    # at fe20c000, 2 channels) is provisional, pending hardware validation
    # (see PLAN.md).
    PWM_CHIP_PROFILE = {
      pi5: { address: "1f00098000", npwm: 4 }.freeze,
      pi4: { address: "fe20c000",   npwm: 2 }.freeze,
    }.freeze

    # @param gpio    [Integer, nil] GPIO line offset to look up chip/channel
    #                 automatically. Takes priority over chip:/channel:.
    # @param chip    [Integer, :auto] pwmchip number, or :auto to detect the
    #                 header PWM chip for the current board.
    # @param channel [Integer] PWM channel number within the chip
    # @param board   [:auto, :pi5, :pi4] board family for the gpio: mapping and
    #                 chip auto-detection. :auto reads the device-tree model.
    def initialize(gpio: nil, chip: :auto, channel: 0, board: :auto)
      @board = board == :auto ? self.class.detect_board : board

      if gpio
        channel = gpio_channel(gpio)
        chip = :auto
      end

      @channel = channel
      @chip_num = chip == :auto ? detect_pwm_chip! : chip
      @chip_path    = "#{PWM_SYSFS_ROOT}/pwmchip#{@chip_num}"
      @channel_path = File.join(@chip_path, "pwm#{@channel}")

      raise PWMError, "PWM chip not found: #{@chip_path}" unless File.exist?(@chip_path)

      @period_ns = nil
      @exported  = false
      export_channel
    end

    # Open a PWM channel, yield it, then close it (disable + unexport).
    def self.open(**, &block)
      pwm = new(**)
      block.call(pwm)
    ensure
      pwm&.close
    end

    # @return [Integer] resolved pwmchip number
    attr_reader :chip_num

    # @return [Integer] channel number within the chip
    attr_reader :channel

    # @return [:pi5, :pi4, :unknown] resolved board family
    attr_reader :board

    # Set PWM frequency in Hz.
    # Updates period_ns; preserves duty cycle ratio if already set.
    # @param hz [Numeric]
    def frequency=(hz)
      new_period_ns = (1_000_000_000.0 / hz).round
      if @period_ns && enabled?
        # Prevent duty_cycle > period violation during update
        write_sysfs("duty_cycle", 0)
      end
      write_sysfs("period", new_period_ns)
      # Restore duty cycle ratio
      write_sysfs("duty_cycle", (@duty_ratio * new_period_ns).round) if @period_ns && @duty_ratio
      @period_ns = new_period_ns
    end

    # @return [Numeric, nil] current frequency in Hz, or nil if period not set
    def frequency
      return nil unless @period_ns&.positive?

      1_000_000_000.0 / @period_ns
    end

    # Set duty cycle as a ratio (0.0–1.0).
    # frequency= must be called first.
    # @param ratio [Float] 0.0 = always off, 1.0 = always on
    def duty_cycle=(ratio)
      raise PWMError, "Set frequency= before duty_cycle=" unless @period_ns

      ratio = ratio.clamp(0.0, 1.0)
      @duty_ratio = ratio
      write_sysfs("duty_cycle", (@duty_ratio * @period_ns).round)
    end

    # @return [Float, nil] current duty cycle ratio
    attr_reader :duty_ratio

    # Set pulse width in microseconds (convenience for servo control).
    # frequency= must be called first.
    # @param us [Numeric] pulse width in microseconds
    def pulse_width_us=(us)
      raise PWMError, "Set frequency= before pulse_width_us=" unless @period_ns

      ns = (us * 1000).round
      @duty_ratio = ns.to_f / @period_ns
      write_sysfs("duty_cycle", ns)
    end

    # @return [Float, nil] current pulse width in microseconds
    def pulse_width_us
      return nil unless @period_ns && @duty_ratio

      (@duty_ratio * @period_ns / 1000.0).round(3)
    end

    # Enable PWM output.
    def enable
      write_sysfs("enable", 1)
      @enabled = true
    end

    # Disable PWM output (pin goes low).
    def disable
      write_sysfs("enable", 0)
      @enabled = false
    end

    def enabled?
      @enabled || false
    end

    # Disable and unexport the PWM channel, freeing the sysfs resource.
    # Safe to call multiple times.
    def close
      return unless @exported

      disable rescue nil
      unexport_channel
      @exported = false
    end

    # Return a human-readable description of this PWM instance.
    def inspect
      "#<Rgpio::HardwarePWM board=#{@board} chip=#{@chip_num} channel=#{@channel} " \
        "freq=#{frequency&.round(2)}Hz duty=#{@duty_ratio&.round(4)} " \
        "enabled=#{enabled?}>"
    end

    # List all available PWM chips with their number of channels.
    # @return [Array<Hash>] [{ chip: Integer, npwm: Integer, path: String }, ...]
    def self.available_chips
      Dir.glob("#{PWM_SYSFS_ROOT}/pwmchip*").filter_map do |path|
        npwm = Integer(File.read(File.join(path, "npwm")).strip, 10) rescue next
        chip_num = File.basename(path).delete_prefix("pwmchip").to_i
        { chip: chip_num, npwm: npwm, path: path }
      end
    end

    # Detect the Raspberry Pi board family from the device-tree model string.
    # @return [:pi5, :pi4, :unknown]
    def self.detect_board(model = board_model)
      case model
      when /Raspberry Pi 5/ then :pi5
      when /Raspberry Pi (?:4|400)/, /Compute Module 4/ then :pi4
      else :unknown
      end
    end

    # @return [String] the device-tree model string ("" when unavailable)
    def self.board_model
      File.read(BOARD_MODEL_PATH, encoding: "BINARY").delete("\0").strip
    rescue SystemCallError
      ""
    end

    private

    # Look up the PWM channel for a header GPIO on the resolved board.
    def gpio_channel(gpio)
      table = GPIO_TO_PWM_CHANNEL.fetch(@board) do
        raise ArgumentError,
              "Hardware PWM gpio: mapping is unknown for board #{@board.inspect}. " \
              "Pass board: :pi5 / :pi4, or chip:/channel: explicitly."
      end
      table.fetch(gpio) do
        raise ArgumentError,
              "GPIO#{gpio} is not a hardware PWM pin on #{@board}. " \
              "Valid pins: #{table.keys.join(", ")}"
      end
    end

    # Resolve the pwmchip number of the header PWM controller for @board.
    #
    # Strategy (in order of preference):
    #   1. Chip whose sysfs device symlink contains the board's PWM address.
    #      On Pi 5 the RP1 also exposes a PWM1 instance (1f0009c000, fan) that
    #      ALSO reports npwm == 4 but is not on the header, so this address
    #      match is required to avoid selecting it.
    #   2. Chip whose channel count matches the board profile.
    #   3. The only chip present.
    #
    # Raises PWMError when no chip can be chosen.
    def detect_pwm_chip!
      chips = self.class.available_chips
      if chips.empty?
        raise PWMError, "No PWM chips found under #{PWM_SYSFS_ROOT}. " \
                        "Is the dtoverlay configured? See README.md."
      end

      profile = PWM_CHIP_PROFILE[@board]
      if profile
        by_address = chips.find do |c|
          device_link = File.readlink(c[:path]) rescue ""
          device_link.include?(profile[:address])
        end
        return by_address[:chip] if by_address

        by_npwm = chips.find { |c| c[:npwm] == profile[:npwm] }
        return by_npwm[:chip] if by_npwm
      end

      # Only one chip present — unambiguous.
      return chips.first[:chip] if chips.size == 1

      # Cannot determine — require explicit chip: argument.
      chip_list = chips.map { |c| "pwmchip#{c[:chip]}(npwm=#{c[:npwm]})" }.join(", ")
      raise PWMError,
            "Cannot auto-detect the header PWM chip for board #{@board.inspect}. " \
            "Available: #{chip_list}. Pass chip: <number> explicitly (see README.md)."
    end

    def export_channel
      return if File.exist?(@channel_path)

      File.write(File.join(@chip_path, "export"), @channel.to_s)
      wait_for_channel_path!
      @exported = true
    rescue Errno::EBUSY
      # Already exported by a previous run that did not unexport cleanly.
      raise unless File.exist?(@channel_path)

      @exported = true
    end

    def unexport_channel
      File.write(File.join(@chip_path, "unexport"), @channel.to_s)
    rescue Errno::EINVAL, Errno::ENOENT
      # Already unexported — nothing to do.
    end

    def wait_for_channel_path!
      # Wait for the `period` file to become writable, not just the directory.
      # The udev rule (99-com.rules) runs chgrp/chmod after the directory appears,
      # so polling only for directory existence creates a race.
      period_path = File.join(@channel_path, "period")
      deadline = Time.now + 3.0
      until File.writable?(period_path)
        raise PWMError, "Timeout: #{period_path} did not become writable after export" if Time.now > deadline

        sleep 0.02
      end
    end

    def write_sysfs(attr, value)
      path = File.join(@channel_path, attr.to_s)
      File.write(path, value.to_s)
    rescue Errno::EACCES => e
      raise PWMError, "Failed to write #{path}: #{e.message} " \
                      "(ensure user is in the gpio group, or run with sudo)"
    rescue Errno::ENOENT, Errno::EPERM => e
      raise PWMError, "Failed to write #{path}: #{e.message}"
    end
  end
end
