require_relative "../test_helper"
require "rgpio"

# Tests for the pure chip-selection logic (Phase 2: multi-board auto-detection).
# These exercise Chip.select_header_chip / detect_path with fabricated chip
# records, so they run on any machine without GPIO hardware.
class ChipTest < Minitest::Test
  # Convenience: build a chip record like Chip.list returns.
  def chip(path, label, num_lines)
    { path: path, name: File.basename(path), label: label, num_lines: num_lines }
  end

  # --- select_header_chip: known SoC labels --------------------------- #

  def test_selects_pi5_rp1
    chips = [
      chip("/dev/gpiochip0", "pinctrl-rp1", 54),
      chip("/dev/gpiochip10", "gpio-brcmstb@107d508500", 32),
    ]
    assert_equal "/dev/gpiochip0",
                 Rgpio::Chip.select_header_chip(chips)[:path]
  end

  def test_selects_pi4_bcm2711
    chips = [chip("/dev/gpiochip0", "pinctrl-bcm2711", 58)]
    assert_equal "/dev/gpiochip0",
                 Rgpio::Chip.select_header_chip(chips)[:path]
  end

  def test_selects_pizero_bcm2835
    chips = [chip("/dev/gpiochip0", "pinctrl-bcm2835", 54)]
    assert_equal "/dev/gpiochip0",
                 Rgpio::Chip.select_header_chip(chips)[:path]
  end

  # Header label wins regardless of device order or line count.
  def test_label_priority_over_order_and_size
    chips = [
      chip("/dev/gpiochip10", "gpio-brcmstb@107d508500", 99),
      chip("/dev/gpiochip0", "pinctrl-rp1", 54),
    ]
    assert_equal "/dev/gpiochip0",
                 Rgpio::Chip.select_header_chip(chips)[:path]
  end

  # First match wins when the same label appears twice (Pi 5 exposes the RP1
  # under both gpiochip0 and gpiochip4); detect_path feeds index-sorted input.
  def test_first_match_wins_for_duplicate_label
    chips = [
      chip("/dev/gpiochip0", "pinctrl-rp1", 54),
      chip("/dev/gpiochip4", "pinctrl-rp1", 54),
    ]
    assert_equal "/dev/gpiochip0",
                 Rgpio::Chip.select_header_chip(chips)[:path]
  end

  # --- select_header_chip: fallback ----------------------------------- #

  # Unknown labels → fall back to the chip with the most lines.
  def test_fallback_to_largest_chip
    chips = [
      chip("/dev/gpiochip0", "some-future-soc", 12),
      chip("/dev/gpiochip1", "some-future-soc", 64),
    ]
    assert_equal "/dev/gpiochip1",
                 Rgpio::Chip.select_header_chip(chips)[:path]
  end

  # --- detect_path ---------------------------------------------------- #

  def test_detect_path_with_records
    chips = [chip("/dev/gpiochip0", "pinctrl-rp1", 54)]
    assert_equal "/dev/gpiochip0", Rgpio::Chip.detect_path(chips)
  end

  def test_detect_path_empty_raises
    err = assert_raises(Rgpio::NotAvailableError) do
      Rgpio::Chip.detect_path([])
    end
    assert_match(/No GPIO chips found/, err.message)
  end

  # --- device_index --------------------------------------------------- #

  def test_device_index_numeric_sort
    paths = ["/dev/gpiochip10", "/dev/gpiochip2", "/dev/gpiochip0"]
    sorted = paths.sort_by { |p| Rgpio::Chip.device_index(p) }
    assert_equal ["/dev/gpiochip0", "/dev/gpiochip2", "/dev/gpiochip10"], sorted
  end

  # --- busy_line_hint / request_failure_message ------------------------ #

  # A pin muxed to I2C/SPI: used, with no consumer (gpioinfo: "kernel").
  def test_hint_for_pin_reserved_by_kernel
    hint = Rgpio::Chip.busy_line_hint({ offset: 2, used: true, consumer: nil })
    assert_match(/GPIO2 is reserved by the kernel/, hint)
    assert_match(/I2C, SPI/, hint)
    assert_match(/pinctrl get 2/, hint)
  end

  def test_hint_for_pin_held_by_another_program
    hint = Rgpio::Chip.busy_line_hint({ offset: 17, used: true, consumer: "rgpio" })
    assert_equal 'GPIO17 is already in use by "rgpio"', hint
  end

  def test_no_hint_for_free_pin
    assert_nil Rgpio::Chip.busy_line_hint({ offset: 4, used: false, consumer: nil })
  end

  # A chip whose line_info answers from a table, without opening hardware.
  def fake_chip(infos)
    chip = Rgpio::Chip.allocate
    chip.define_singleton_method(:line_info) do |offset|
      infos.fetch(offset) { raise Errno::EINVAL, "gpiod_chip_get_line_info(#{offset})" }
    end
    chip
  end

  def test_failure_message_names_busy_lines_only
    chip = fake_chip(
      2 => { offset: 2, used: true, consumer: nil },
      4 => { offset: 4, used: false, consumer: nil }
    )
    msg = chip.send(:request_failure_message, [2, 4])
    assert_match(/\Agpiod_chip_request_lines: GPIO2 is reserved/, msg)
    refute_match(/GPIO4/, msg)
  end

  def test_failure_message_ignores_lookup_errors
    msg = fake_chip({}).send(:request_failure_message, [99])
    assert_equal "gpiod_chip_request_lines", msg
  end

  # The errno class stays the kernel's; only the message gains the hint.
  def test_failure_message_keeps_errno_class
    msg = fake_chip(2 => { offset: 2, used: true, consumer: nil })
          .send(:request_failure_message, [2])
    err = SystemCallError.new(msg, Errno::EINVAL::Errno)
    assert_instance_of Errno::EINVAL, err
    assert_match(/Invalid argument - gpiod_chip_request_lines: GPIO2/, err.message)
  end
end
