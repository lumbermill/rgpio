require_relative "../test_helper"
require "rgpio"

# Hardware-free tests for the I2C device drivers. Both classes accept an `i2c:`
# so the bus device can be shared; these tests pass a fake one instead, which
# keeps /dev/i2c-N (and any hardware) out of the picture.
class I2CDevicesTest < Minitest::Test
  # Records every write and answers reads from a canned register map.
  class FakeI2C
    attr_reader :writes, :closed
    attr_accessor :registers

    def initialize(registers = {})
      @registers = registers
      @writes = []
      @closed = false
    end

    def write(*bytes)
      flat = bytes.flatten.flat_map { |b| b.is_a?(String) ? b.b.bytes : [b] }
      @writes << flat
      flat.size
    end

    def write_register(register, *bytes)
      write(register, *bytes)
    end

    def read_register(register, count = 1)
      Array(@registers.fetch(register)).first(count)
    end

    def close
      @closed = true
    end
  end

  # The 200 ms power-on wait would dominate the suite; the sequence it separates
  # is what the tests are about.
  class FastST7032 < Rgpio::ST7032
    def sleep(*) = nil
  end

  def adt7410_registers
    { 0x00 => [0x0c, 0x80], 0x03 => [0x00], 0x0b => [0xcb] }
  end

  # --- ADT7410 -------------------------------------------------------------

  def test_adt7410_converts_13_bit_readings
    assert_in_delta 25.0, Rgpio::ADT7410.convert(0x0c, 0x80)
    assert_in_delta 0.0, Rgpio::ADT7410.convert(0x00, 0x00)
    assert_in_delta 0.0625, Rgpio::ADT7410.convert(0x00, 0x08)
  end

  # Datasheet Table 7 gives the 13-bit codes 0x1e70 (-25 degC) and 0x1c90
  # (-55 degC); the register holds them shifted up by the three flag bits.
  def test_adt7410_converts_negative_13_bit_readings
    assert_in_delta(-1.0, Rgpio::ADT7410.convert(0xff, 0x80))
    assert_in_delta(-25.0, Rgpio::ADT7410.convert(0xf3, 0x80))
    assert_in_delta(-55.0, Rgpio::ADT7410.convert(0xe4, 0x80))
  end

  def test_adt7410_ignores_the_three_flag_bits_in_13_bit_mode
    # Tcrit/Thigh/Tlow set: the temperature must read the same as with them clear.
    assert_in_delta Rgpio::ADT7410.convert(0x0c, 0x80), Rgpio::ADT7410.convert(0x0c, 0x87)
  end

  def test_adt7410_converts_16_bit_readings
    assert_in_delta 50.0, Rgpio::ADT7410.convert(0x19, 0x00, 16)
    assert_in_delta(-1.0, Rgpio::ADT7410.convert(0xff, 0x80, 16))
    assert_in_delta 0.0078125, Rgpio::ADT7410.convert(0x00, 0x01, 16)
  end

  def test_adt7410_reads_the_temperature_register
    bus = FakeI2C.new(adt7410_registers)
    sensor = Rgpio::ADT7410.new(i2c: bus)

    assert_in_delta 25.0, sensor.temperature
    assert_equal [0x0c, 0x80], sensor.raw_temperature
  end

  def test_adt7410_selects_the_requested_resolution
    bus = FakeI2C.new(adt7410_registers)
    sensor = Rgpio::ADT7410.new(i2c: bus, resolution: 16)

    assert_equal 16, sensor.resolution
    assert_equal [0x03, 0x80], bus.writes.last, "config register should have the 16-bit bit set"

    sensor.resolution = 13

    assert_equal [0x03, 0x00], bus.writes.last
  end

  def test_adt7410_rejects_an_unsupported_resolution
    bus = FakeI2C.new(adt7410_registers)

    assert_raises(ArgumentError) { Rgpio::ADT7410.new(i2c: bus, resolution: 12) }
  end

  def test_adt7410_detects_the_manufacturer_id
    bus = FakeI2C.new(adt7410_registers)
    sensor = Rgpio::ADT7410.new(i2c: bus)

    assert_equal 0xcb, sensor.id
    assert_predicate sensor, :detected?

    bus.registers[0x0b] = [0x00]

    refute_predicate sensor, :detected?
  end

  def test_adt7410_closes_only_a_bus_device_it_opened
    bus = FakeI2C.new(adt7410_registers)
    sensor = Rgpio::ADT7410.new(i2c: bus)
    sensor.close

    assert_predicate sensor, :closed?
    refute bus.closed, "a shared bus device must outlive the sensor"
  end

  # --- ST7032 --------------------------------------------------------------

  def test_st7032_runs_the_power_on_sequence
    bus = FakeI2C.new
    FastST7032.new(i2c: bus)

    # Every transfer is a control byte plus one payload byte.
    assert(bus.writes.all? { |w| w.size == 2 && w.first.zero? })
    assert_equal [0x38, 0x39, 0x14, 0x70, 0x56, 0x6c, 0x38, 0x0c, 0x06, 0x01],
                 bus.writes.map(&:last)
  end

  def test_st7032_contrast_is_split_across_the_two_instructions
    bus = FakeI2C.new
    lcd = FastST7032.new(i2c: bus, contrast: 0x0a)

    assert_includes bus.writes.map(&:last), 0x7a  # C3..C0 = 0b1010
    assert_includes bus.writes.map(&:last), 0x54  # booster on, C5..C4 = 0b00

    lcd.contrast = 0x3f

    assert_equal [0x39, 0x7f, 0x57, 0x38], bus.writes.last(4).map(&:last)
    assert_equal 0x3f, lcd.contrast
  end

  def test_st7032_can_leave_the_booster_off
    bus = FakeI2C.new
    FastST7032.new(i2c: bus, booster: false)

    assert_includes bus.writes.map(&:last), 0x52
  end

  def test_st7032_rejects_an_out_of_range_contrast
    assert_raises(ArgumentError) { FastST7032.new(i2c: FakeI2C.new, contrast: 64) }
  end

  def test_st7032_writes_text_as_display_data
    bus = FakeI2C.new
    lcd = FastST7032.new(i2c: bus)
    bus.writes.clear
    lcd.print("Hi")

    assert_equal [[0x40, 0x48, 0x69]], bus.writes
  end

  def test_st7032_moves_to_the_second_row_on_a_newline
    bus = FakeI2C.new
    lcd = FastST7032.new(i2c: bus)
    bus.writes.clear
    lcd.print("ab\ncd")

    assert_equal [[0x40, 0x61, 0x62], [0x00, 0x80 | 0x40], [0x40, 0x63, 0x64]], bus.writes
  end

  def test_st7032_drops_text_that_would_run_past_the_row
    bus = FakeI2C.new
    lcd = FastST7032.new(i2c: bus, columns: 8)
    bus.writes.clear
    lcd.print("0123456789")

    assert_equal [[0x40] + "01234567".bytes], bus.writes
  end

  def test_st7032_drops_rows_past_the_last_one
    bus = FakeI2C.new
    lcd = FastST7032.new(i2c: bus)
    bus.writes.clear
    lcd.print("a\nb\nc")

    assert_equal [[0x40, 0x61], [0x00, 0xc0], [0x40, 0x62]], bus.writes
  end

  def test_st7032_message_clears_before_writing
    bus = FakeI2C.new
    lcd = FastST7032.new(i2c: bus)
    bus.writes.clear
    lcd.message = "hi"

    assert_equal [[0x00, 0x01], [0x40, 0x68, 0x69]], bus.writes
  end

  def test_st7032_move_to_sets_the_ddram_address
    bus = FakeI2C.new
    lcd = FastST7032.new(i2c: bus)
    bus.writes.clear
    lcd.move_to(3, 1)

    assert_equal [[0x00, 0x80 | 0x43]], bus.writes
    assert_raises(ArgumentError) { lcd.move_to(8, 0) }
    assert_raises(ArgumentError) { lcd.move_to(0, 2) }
  end

  def test_st7032_display_can_be_switched_off_and_on
    bus = FakeI2C.new
    lcd = FastST7032.new(i2c: bus)
    bus.writes.clear
    lcd.display_off
    lcd.display_on

    assert_equal [[0x00, 0x08], [0x00, 0x0c]], bus.writes
  end

  def test_st7032_closes_only_a_bus_device_it_opened
    bus = FakeI2C.new
    lcd = FastST7032.new(i2c: bus)
    lcd.close

    assert_predicate lcd, :closed?
    refute bus.closed, "a shared bus device must outlive the display"
  end
end
