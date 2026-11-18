require_relative "../test_helper"
require "fiddle"
require "rgpio"

# Hardware-free tests for LineRequest and the Native offset buffer. These avoid any libgpiod call (and any libgpiod enum
# constant), so they run on CI without GPIO hardware or the shared library.
class LineRequestTest < Minitest::Test
  # --- Native offset buffer (pure packing) --------------------------- #

  def test_uint32_buffer_roundtrip
    ptr = Rgpio::Native.uint32_buffer([17, 27, 22])
    assert_equal [17, 27, 22], ptr[0, 3 * 4].unpack("L*")
  end

  # --- set_values: argument validation (no native call) --------------- #

  def test_set_values_rejects_non_hash
    req = Rgpio::LineRequest.new(Fiddle::NULL, [17, 27])
    assert_raises(ArgumentError) { req.set_values([17, 27]) }
  end

  def test_set_values_empty_hash_is_noop
    req = Rgpio::LineRequest.new(Fiddle::NULL, [17, 27])
    assert_nil req.set_values({})
  end

  def test_get_values_empty_offsets_returns_empty_hash
    req = Rgpio::LineRequest.new(Fiddle::NULL, [17, 27])
    assert_equal({}, req.get_values([]))
  end

  # --- released state ------------------------------------------------- #

  def test_batch_ops_raise_after_release
    req = Rgpio::LineRequest.new(Fiddle::NULL, [17, 27])
    # Simulate a released request without touching a real native pointer.
    req.instance_variable_set(:@request_ptr, nil)
    assert req.released?
    assert_raises(Rgpio::Error) { req.get_values }
    assert_raises(Rgpio::Error) { req.set_values(17 => :active) }
  end

  # --- value ioctls: numbers and struct gpio_v2_line_values --------- #

  # The literals are GPIO_V2_LINE_GET_VALUES_IOCTL / _SET_VALUES_IOCTL as
  # <linux/gpio.h> expands them.
  def test_value_ioctl_numbers_match_linux_gpio_h
    assert_equal 0xC010B40E, Rgpio::LineRequest::GET_VALUES_IOCTL
    assert_equal 0xC010B40F, Rgpio::LineRequest::SET_VALUES_IOCTL
  end

  def test_line_values_are_two_u64_plus_a_sentinel_byte
    buffer = Rgpio::LineRequest.pack_line_values(0b101, 0b111)
    assert_equal 17, buffer.bytesize
    assert_equal [0b101, 0b111], buffer.unpack("QQ")
    refute_predicate buffer, :frozen?
  end

  # Bit 63 is the 64th line of a request, the kernel maximum.
  def test_line_values_carry_the_high_bits
    buffer = Rgpio::LineRequest.pack_line_values(1 << 63, (1 << 64) - 1)
    assert_equal 1 << 63, Rgpio::LineRequest.unpack_line_bits(buffer)
  end

  def test_unknown_offset_is_einval_naming_the_request
    req = Rgpio::LineRequest.new(Fiddle::NULL, [17, 27])
    error = assert_raises(Errno::EINVAL) { req.set_value(22, :active) }
    assert_match(/GPIO22 is not in this request \(offsets: 17, 27\)/, error.message)
    assert_raises(Errno::EINVAL) { req.get_value(22) }
    assert_raises(Errno::EINVAL) { req.get_values([17, 22]) }
    assert_raises(Errno::EINVAL) { req.set_values(22 => :active) }
  end

  def test_offsets_is_frozen_and_readable
    req = Rgpio::LineRequest.new(Fiddle::NULL, [17, 27])
    assert_equal [17, 27], req.offsets
    assert_predicate req.offsets, :frozen?
  end
end
