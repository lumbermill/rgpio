require_relative "../test_helper"
require "rgpio"

# Hardware-free tests for Rgpio::SPI and the MCP3208 driver. Opening a bus needs
# a real /dev/spidevB.D, so what is covered here is the ioctl encoding, the
# struct layout and the converter's protocol — the places where a mistake gives
# plausible-looking wrong numbers rather than an exception.
class SPITest < Minitest::Test
  # Values read off <linux/spi/spidev.h>: direction in bits 30-31, size in
  # 16-29, the 'k' magic in 8-15, request in 0-7.
  def test_ioctl_numbers_match_the_kernel_header
    assert_equal 0x40206b00, Rgpio::SPI.message_ioctl(1)
    assert_equal 0x40406b00, Rgpio::SPI.message_ioctl(2)
    assert_equal 0x40016b01, Rgpio::SPI::IOC_WR_MODE
    assert_equal 0x80016b01, Rgpio::SPI::IOC_RD_MODE
    assert_equal 0x40016b03, Rgpio::SPI::IOC_WR_BITS_PER_WORD
    assert_equal 0x40046b04, Rgpio::SPI::IOC_WR_MAX_SPEED_HZ
    assert_equal 0x80046b04, Rgpio::SPI::IOC_RD_MAX_SPEED_HZ
  end

  def test_pack_transfer_matches_the_kernel_struct_layout
    message = Rgpio::SPI.pack_transfer(0xdead_beef, 0xcafe_f00d, 3, 500_000,
                                       bits_per_word: 8, delay_us: 7, cs_change: true)

    assert_equal Rgpio::SPI::TRANSFER_SIZE, message.bytesize
    assert_equal 0xdead_beef, message[0, 8].unpack1("Q")
    assert_equal 0xcafe_f00d, message[8, 8].unpack1("Q")
    assert_equal 3, message[16, 4].unpack1("L")
    assert_equal 500_000, message[20, 4].unpack1("L")
    assert_equal 7, message[24, 2].unpack1("S")
    assert_equal 8, message[26, 1].unpack1("C")
    assert_equal 1, message[27, 1].unpack1("C"), "cs_change"
    assert_equal "\0\0\0\0", message[28, 4], "tx_nbits, rx_nbits, word_delay_usecs and pad must be zero"
  end

  def test_devices_lists_bus_and_chip_select_pairs
    devices = Rgpio::SPI.devices

    assert_kind_of Array, devices
    assert(devices.all? { |pair| pair.size == 2 && pair.all?(Integer) })
    assert_equal devices.sort, devices
  end

  def test_reports_a_missing_bus_with_the_dtparam_hint
    error = assert_raises(Rgpio::SPIError) { Rgpio::SPI.new(bus: 9, device: 9) }

    assert_match(%r{/dev/spidev9\.9}, error.message)
    assert_match(/dtparam=spi=on/, error.message)
  end

  # --- MCP3208 ------------------------------------------------------------

  # Answers every transfer with a canned frame and records what it was asked to
  # send. The converter's reply is three bytes: the first is ignored, then four
  # null bits and the twelve data bits.
  class FakeSPI
    attr_reader :transfers, :closed
    attr_accessor :code

    def initialize(code: 0)
      @code = code
      @transfers = []
      @closed = false
    end

    def transfer(bytes)
      @transfers << bytes
      [0x00, (@code >> 8) & 0x0f, @code & 0xff]
    end

    def close
      @closed = true
    end
  end

  def test_mcp3208_sends_the_single_ended_command_for_each_channel
    bus = FakeSPI.new
    adc = Rgpio::MCP3208.new(spi: bus)

    (0..7).each { |channel| adc.read(channel) }

    assert_equal [[0x06, 0x00, 0x00], [0x06, 0x40, 0x00], [0x06, 0x80, 0x00], [0x06, 0xc0, 0x00],
                  [0x07, 0x00, 0x00], [0x07, 0x40, 0x00], [0x07, 0x80, 0x00], [0x07, 0xc0, 0x00],],
                 bus.transfers
  end

  def test_mcp3208_sends_the_differential_command_when_asked
    bus = FakeSPI.new
    adc = Rgpio::MCP3208.new(spi: bus)
    adc.read(0, differential: true)
    adc.read(5, differential: true)

    assert_equal [[0x04, 0x00, 0x00], [0x05, 0x40, 0x00]], bus.transfers
  end

  def test_mcp3208_assembles_the_twelve_bit_code
    bus = FakeSPI.new
    adc = Rgpio::MCP3208.new(spi: bus)

    bus.code = 0
    assert_equal 0, adc.read(0)

    bus.code = 4095
    assert_equal 4095, adc.read(0)

    bus.code = 2048
    assert_equal 2048, adc.read(0)

    bus.code = 0x123
    assert_equal 0x123, adc.read(0)
  end

  # The frame's first byte is whatever the part clocked out while the command
  # was still arriving; treating it as data would ruin every reading.
  def test_mcp3208_ignores_the_first_byte_of_the_frame
    bus = FakeSPI.new(code: 100)
    def bus.transfer(bytes)
      @transfers << bytes
      [0xff, (@code >> 8) & 0x0f, @code & 0xff]
    end
    adc = Rgpio::MCP3208.new(spi: bus)

    assert_equal 100, adc.read(0)
  end

  def test_mcp3208_converts_to_a_ratio_and_to_volts
    bus = FakeSPI.new(code: 4095)
    adc = Rgpio::MCP3208.new(spi: bus, reference_voltage: 3.3)

    assert_in_delta 1.0, adc.value(0)
    assert_in_delta 3.3, adc.voltage(0)

    bus.code = 2048

    assert_in_delta 0.5, adc.value(0), 0.001
    assert_in_delta 1.65, adc.voltage(0), 0.01
  end

  def test_mcp3208_rejects_a_channel_it_does_not_have
    adc = Rgpio::MCP3208.new(spi: FakeSPI.new)

    assert_raises(ArgumentError) { adc.read(8) }
    assert_raises(ArgumentError) { adc.read(-1) }

    mcp3204 = Rgpio::MCP3208.new(spi: FakeSPI.new, channels: 4)

    assert_raises(ArgumentError) { mcp3204.read(4) }
    assert_equal 4, mcp3204.read_all.size
  end

  def test_mcp3208_reads_every_channel_in_turn
    bus = FakeSPI.new(code: 7)
    adc = Rgpio::MCP3208.new(spi: bus)

    assert_equal [7] * 8, adc.read_all
    assert_equal 8, bus.transfers.size
  end

  def test_mcp3208_closes_only_a_bus_device_it_opened
    bus = FakeSPI.new
    adc = Rgpio::MCP3208.new(spi: bus)
    adc.close

    assert_predicate adc, :closed?
    refute bus.closed, "a shared bus device must outlive the converter"
    assert_raises(Rgpio::Error) { adc.read(0) }
  end
end
