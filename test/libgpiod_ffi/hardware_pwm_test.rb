# frozen_string_literal: true

require_relative "../test_helper"
require "libgpiod_ffi"

class HardwarePWMTest < Minitest::Test
  def setup
    @sysfs_root = Dir.mktmpdir("libgpiod_ffi_test_")
    @original_root = LibgpiodFFI::HardwarePWM::PWM_SYSFS_ROOT
    LibgpiodFFI::HardwarePWM.send(:remove_const, :PWM_SYSFS_ROOT)
    LibgpiodFFI::HardwarePWM.const_set(:PWM_SYSFS_ROOT, @sysfs_root)
  end

  def teardown
    FileUtils.rm_rf(@sysfs_root)
    LibgpiodFFI::HardwarePWM.send(:remove_const, :PWM_SYSFS_ROOT)
    LibgpiodFFI::HardwarePWM.const_set(:PWM_SYSFS_ROOT, @original_root)
  end

  # --- helpers ---

  # Adds a fake pwmchipN entry.
  # rp1_address: (e.g. "1f00098000") creates a real symlink so that
  #   File.readlink returns a path containing that address — no mocking needed.
  def add_chip(num:, npwm:, rp1_address: nil)
    if rp1_address
      real_dir = File.join(@sysfs_root, "devices", "platform", "soc",
                           "#{rp1_address}.pwm", "pwm", "pwmchip#{num}")
      FileUtils.mkdir_p(real_dir)
      File.write(File.join(real_dir, "npwm"), "#{npwm}\n")
      link_path = File.join(@sysfs_root, "pwmchip#{num}")
      relative  = File.join("devices", "platform", "soc",
                            "#{rp1_address}.pwm", "pwm", "pwmchip#{num}")
      File.symlink(relative, link_path)
    else
      dir = File.join(@sysfs_root, "pwmchip#{num}")
      Dir.mkdir(dir)
      File.write(File.join(dir, "npwm"), "#{npwm}\n")
    end
  end

  # Creates a pre-exported channel directory so initialize skips the export step.
  def add_channel(chip_num:, channel:)
    dir = File.join(@sysfs_root, "pwmchip#{chip_num}", "pwm#{channel}")
    FileUtils.mkdir_p(dir)
    %w[period duty_cycle enable].each { |f| File.write(File.join(dir, f), "0") }
  end

  def pwm_for_gpio18
    add_chip(num: 2, npwm: 4, rp1_address: "1f00098000")
    add_channel(chip_num: 2, channel: 2)
    LibgpiodFFI::HardwarePWM.new(gpio: 18)
  end

  # ------------------------------------------------------------------ #
  # GPIO_TO_PWM_CHANNEL_PI5

  def test_gpio_to_pwm_channel_mapping
    assert_equal({ 12 => 0, 13 => 1, 18 => 2, 19 => 3 },
                 LibgpiodFFI::HardwarePWM::GPIO_TO_PWM_CHANNEL_PI5)
  end

  # ------------------------------------------------------------------ #
  # .new argument validation

  def test_new_gpio_invalid_raises_argument_error
    err = assert_raises(ArgumentError) { LibgpiodFFI::HardwarePWM.new(gpio: 17) }
    assert_match(/GPIO17.*not a hardware PWM pin/, err.message)
  end

  def test_new_chip_missing_raises_pwm_error
    err = assert_raises(LibgpiodFFI::PWMError) { LibgpiodFFI::HardwarePWM.new(chip: 99, channel: 0) }
    assert_match(/PWM chip not found.*pwmchip99/, err.message)
  end

  # ------------------------------------------------------------------ #
  # .available_chips

  def test_available_chips_empty
    assert_empty LibgpiodFFI::HardwarePWM.available_chips
  end

  def test_available_chips_sorted
    add_chip(num: 0, npwm: 2)
    add_chip(num: 2, npwm: 4)
    expected = [
      { chip: 0, npwm: 2, path: "#{@sysfs_root}/pwmchip0" },
      { chip: 2, npwm: 4, path: "#{@sysfs_root}/pwmchip2" },
    ]
    assert_equal expected, LibgpiodFFI::HardwarePWM.available_chips
  end

  # ------------------------------------------------------------------ #
  # RP1 chip auto-detection

  def test_detect_strategy1_rp1_address_in_symlink
    add_chip(num: 0, npwm: 2)
    add_chip(num: 2, npwm: 4, rp1_address: "1f00098000")
    add_channel(chip_num: 2, channel: 2)
    pwm = LibgpiodFFI::HardwarePWM.new(gpio: 18)
    assert_equal 2, pwm.chip_num
  end

  def test_detect_strategy2_npwm_4
    add_chip(num: 0, npwm: 2)
    add_chip(num: 2, npwm: 4)
    add_channel(chip_num: 2, channel: 0)
    pwm = LibgpiodFFI::HardwarePWM.new(chip: :auto, channel: 0)
    assert_equal 2, pwm.chip_num
  end

  def test_detect_strategy3_single_chip
    add_chip(num: 3, npwm: 2)
    add_channel(chip_num: 3, channel: 0)
    pwm = LibgpiodFFI::HardwarePWM.new(chip: :auto, channel: 0)
    assert_equal 3, pwm.chip_num
  end

  def test_detect_no_chips_raises_pwm_error
    err = assert_raises(LibgpiodFFI::PWMError) { LibgpiodFFI::HardwarePWM.new(chip: :auto, channel: 0) }
    assert_match(/No PWM chips found/, err.message)
  end

  def test_detect_ambiguous_raises_pwm_error
    add_chip(num: 0, npwm: 2)
    add_chip(num: 2, npwm: 2)
    err = assert_raises(LibgpiodFFI::PWMError) { LibgpiodFFI::HardwarePWM.new(chip: :auto, channel: 0) }
    assert_match(/Cannot auto-detect.*pwmchip/, err.message)
  end

  # ------------------------------------------------------------------ #
  # frequency, duty cycle, pulse width

  def test_frequency_50hz
    pwm = pwm_for_gpio18
    pwm.frequency = 50
    assert_in_delta 50.0, pwm.frequency, 0.01
  end

  def test_frequency_1khz
    pwm = pwm_for_gpio18
    pwm.frequency = 1_000
    assert_in_delta 1_000.0, pwm.frequency, 0.1
  end

  def test_duty_cycle_stores_ratio
    pwm = pwm_for_gpio18
    pwm.frequency = 50
    pwm.duty_cycle = 0.075
    assert_in_delta 0.075, pwm.duty_ratio, 1e-9
  end

  def test_duty_cycle_clamps_above_1
    pwm = pwm_for_gpio18
    pwm.frequency = 50
    pwm.duty_cycle = 1.5
    assert_equal 1.0, pwm.duty_ratio
  end

  def test_duty_cycle_clamps_below_0
    pwm = pwm_for_gpio18
    pwm.frequency = 50
    pwm.duty_cycle = -0.1
    assert_equal 0.0, pwm.duty_ratio
  end

  def test_duty_cycle_without_frequency_raises
    add_chip(num: 2, npwm: 4)
    add_channel(chip_num: 2, channel: 2)
    pwm = LibgpiodFFI::HardwarePWM.new(chip: 2, channel: 2)
    err = assert_raises(LibgpiodFFI::PWMError) { pwm.duty_cycle = 0.5 }
    assert_match(/Set frequency=/, err.message)
  end

  def test_pulse_width_roundtrip
    pwm = pwm_for_gpio18
    pwm.frequency = 50
    pwm.pulse_width_us = 1500
    assert_in_delta 1500, pwm.pulse_width_us, 1
  end

  def test_pulse_width_nil_before_set
    add_chip(num: 2, npwm: 4)
    add_channel(chip_num: 2, channel: 2)
    pwm = LibgpiodFFI::HardwarePWM.new(chip: 2, channel: 2)
    assert_nil pwm.pulse_width_us
  end

  def test_pulse_width_without_frequency_raises
    add_chip(num: 2, npwm: 4)
    add_channel(chip_num: 2, channel: 2)
    pwm = LibgpiodFFI::HardwarePWM.new(chip: 2, channel: 2)
    err = assert_raises(LibgpiodFFI::PWMError) { pwm.pulse_width_us = 1500 }
    assert_match(/Set frequency=/, err.message)
  end

  # ------------------------------------------------------------------ #
  # #inspect

  def test_inspect_format
    add_chip(num: 2, npwm: 4)
    add_channel(chip_num: 2, channel: 0)
    pwm = LibgpiodFFI::HardwarePWM.new(chip: 2, channel: 0)
    assert_match(/chip=2.*channel=0.*enabled=false/, pwm.inspect)
  end
end
