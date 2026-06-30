# frozen_string_literal: true

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
end
