require_relative "../test_helper"
require "rgpio"

# Hardware-free tests for Rgpio::I2C. Opening a device needs a real /dev/i2c-N
# (ioctl on a regular file fails with ENOTTY), so what is covered here is the
# argument handling and the ioctl struct packing — the part where a mistake
# would be a silently corrupt transfer rather than an exception.
class I2CTest < Minitest::Test
  def test_pack_msg_matches_the_kernel_struct_layout
    msg = Rgpio::I2C.pack_msg(0x48, Rgpio::I2C::I2C_M_RD, 2, 0xdead_beef)

    assert_equal Rgpio::I2C::MSG_SIZE, msg.bytesize
    addr, flags, len = msg[0, 6].unpack("SSS")

    assert_equal 0x48, addr
    assert_equal 1, flags
    assert_equal 2, len
    assert_equal 0xdead_beef, msg[Rgpio::I2C::MSG_BUF_OFFSET, Fiddle::SIZEOF_VOIDP].unpack1("J")
  end

  def test_pack_msg_pads_the_pointer_to_its_alignment
    msg = Rgpio::I2C.pack_msg(0x3e, 0, 1, 0)

    assert_equal "\0\0", msg[6, 2], "bytes between len and buf must be zero padding"
  end

  def test_pack_rdwr_carries_the_message_pointer_and_count
    data = Rgpio::I2C.pack_rdwr(0x1000, 2)

    assert_equal Rgpio::I2C::RDWR_SIZE, data.bytesize
    assert_equal 0x1000, data[0, Fiddle::SIZEOF_VOIDP].unpack1("J")
    assert_equal 2, data[Fiddle::SIZEOF_VOIDP, 4].unpack1("L")
  end

  def test_bytes_pack_accepts_integers_strings_and_arrays
    assert_equal "\x40Hi".b, Rgpio::Bytes.pack([0x40, "Hi"])
    assert_equal "\x00\x38".b, Rgpio::Bytes.pack([0x00, 0x38])
    assert_equal "\x40\x01\x02".b, Rgpio::Bytes.pack([0x40, [1, 2]])
    assert_empty Rgpio::Bytes.pack([])
  end

  def test_buses_lists_device_nodes_as_sorted_integers
    buses = Rgpio::I2C.buses

    assert_kind_of Array, buses
    assert(buses.all?(Integer))
    assert_equal buses.sort, buses
  end

  def test_rejects_addresses_outside_the_addressable_range
    assert_raises(ArgumentError) { Rgpio::I2C.new(address: 0x00) }
    assert_raises(ArgumentError) { Rgpio::I2C.new(address: 0x78) }
  end

  def test_reports_a_missing_bus_with_the_dtparam_hint
    error = assert_raises(Rgpio::I2CError) { Rgpio::I2C.new(address: 0x48, bus: 99) }

    assert_match(%r{/dev/i2c-99}, error.message)
    assert_match(/dtparam=i2c_arm=on/, error.message)
  end
end
