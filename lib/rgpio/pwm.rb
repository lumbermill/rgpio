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

    # GPIO offset → [pwm_chip_label_hint, channel] for Raspberry Pi 5 (RP1).
    # The chip number is resolved at runtime via auto-detection.
    GPIO_TO_PWM_CHANNEL_PI5 = {
      12 => 0,
      13 => 1,
      18 => 2,
      19 => 3
    }.freeze

    # @param gpio    [Integer, nil] GPIO line offset to look up chip/channel
    #                              automatically (Pi 5 only). Takes priority.
    # @param chip    [Integer, :auto] pwmchip number, or :auto to detect RP1
    # @param channel [Integer] PWM channel number within the chip
    def initialize(gpio: nil, chip: :auto, channel: 0)
      if gpio
        channel = GPIO_TO_PWM_CHANNEL_PI5.fetch(gpio) do
          raise ArgumentError,
                "GPIO#{gpio} is not a hardware PWM pin on Pi 5. " \
                "Valid pins: #{GPIO_TO_PWM_CHANNEL_PI5.keys.join(', ')}"
        end
        chip = :auto
      end

      @channel = channel
      @chip_num = chip == :auto ? detect_rp1_pwm_chip! : chip
      @chip_path    = "#{PWM_SYSFS_ROOT}/pwmchip#{@chip_num}"
      @channel_path = File.join(@chip_path, "pwm#{@channel}")

      raise PWMError, "PWM chip not found: #{@chip_path}" unless File.exist?(@chip_path)

      @period_ns    = nil
      @exported     = false
      export_channel
    end

    # Open a PWM channel, yield it, then close it (disable + unexport).
    def self.open(**kwargs, &block)
      pwm = new(**kwargs)
      block.call(pwm)
    ensure
      pwm&.close
    end

    # @return [Integer] resolved pwmchip number
    attr_reader :chip_num

    # @return [Integer] channel number within the chip
    attr_reader :channel

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
      if @period_ns && @duty_ratio
        write_sysfs("duty_cycle", (@duty_ratio * new_period_ns).round)
      end
      @period_ns = new_period_ns
    end

    # @return [Numeric, nil] current frequency in Hz, or nil if period not set
    def frequency
      return nil unless @period_ns && @period_ns > 0
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
      "#<Rgpio::HardwarePWM chip=#{@chip_num} channel=#{@channel} " \
        "freq=#{frequency&.round(2)}Hz duty=#{@duty_ratio&.round(4)} " \
        "enabled=#{enabled?}>"
    end

    # List all available PWM chips with their number of channels.
    # @return [Array<Hash>] [{ chip: Integer, npwm: Integer, path: String }, ...]
    def self.available_chips
      Dir.glob("#{PWM_SYSFS_ROOT}/pwmchip*").sort.filter_map do |path|
        npwm = Integer(File.read(File.join(path, "npwm")).strip, 10) rescue next
        chip_num = File.basename(path).delete_prefix("pwmchip").to_i
        { chip: chip_num, npwm: npwm, path: path }
      end
    end

    private

    # Detect the RP1 PWM chip on Raspberry Pi 5.
    #
    # Strategy (in order of preference):
    #   1. Chip whose sysfs device symlink path is the RP1 PWM0 instance
    #      (address 1f00098000). This is the peripheral the 40-pin header
    #      pins route to: GPIO12/13/18/19 = PWM0_CHAN0..3 (verified via
    #      `pinctrl funcs`).
    #      NOTE: RP1 also has a PWM1 instance (1f0009c000) which is enabled by
    #      default (fan) and ALSO reports npwm == 4 but is not wired to the
    #      header — so this address match is required to avoid selecting it.
    #   2. Chip with npwm == 4 (fallback when only one PWM instance is present).
    #   3. The only chip present.
    #
    # Raises PWMError if no chip can be found.
    def detect_rp1_pwm_chip!
      chips = self.class.available_chips
      raise PWMError, "No PWM chips found under #{PWM_SYSFS_ROOT}. " \
                      "Is the dtoverlay configured? See README.md." if chips.empty?

      # Strategy 1: RP1 PWM0 device address in sysfs symlink path
      rp1_candidate = chips.find do |c|
        device_link = File.readlink(c[:path]) rescue ""
        device_link.include?("1f00098000")
      end
      return rp1_candidate[:chip] if rp1_candidate

      # Strategy 2: chip with 4 PWM channels (RP1 GPIO-header PWM)
      four_ch = chips.find { |c| c[:npwm] == 4 }
      return four_ch[:chip] if four_ch

      # Strategy 3: only one chip available
      return chips.first[:chip] if chips.size == 1

      # Cannot determine — require explicit chip: argument
      chip_list = chips.map { |c| "pwmchip#{c[:chip]}(npwm=#{c[:npwm]})" }.join(", ")
      raise PWMError,
            "Cannot auto-detect RP1 PWM chip. Available: #{chip_list}. " \
            "Pass chip: <number> explicitly (see README.md)."
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
