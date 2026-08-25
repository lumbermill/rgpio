# frozen_string_literal: true

require_relative "../test_helper"
require "fiddle"
require "rgpio"

# Hardware-free tests for LineRequest and the Native buffer helpers that back
# batch multi-line I/O. These avoid any libgpiod call (and any libgpiod enum
# constant), so they run on CI without GPIO hardware or the shared library.
class LineRequestTest < Minitest::Test
  # --- Native buffer helpers (pure packing/unpacking) ----------------- #

  def test_uint32_buffer_roundtrip
    ptr = Rgpio::Native.uint32_buffer([17, 27, 22])
    assert_equal [17, 27, 22], ptr[0, 3 * 4].unpack("L*")
  end

  def test_int_buffer_roundtrip
    ptr = Rgpio::Native.int_buffer([1, 0, 1, 0])
    assert_equal [1, 0, 1, 0], Rgpio::Native.read_int_buffer(ptr, 4)
  end

  def test_int_output_buffer_is_writable_and_reads_back
    ptr = Rgpio::Native.int_output_buffer(3)
    ptr[0, 3 * Fiddle::SIZEOF_INT] = [5, 6, 7].pack("l*")
    assert_equal [5, 6, 7], Rgpio::Native.read_int_buffer(ptr, 3)
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

  def test_offsets_is_frozen_and_readable
    req = Rgpio::LineRequest.new(Fiddle::NULL, [17, 27])
    assert_equal [17, 27], req.offsets
    assert_predicate req.offsets, :frozen?
  end
end
