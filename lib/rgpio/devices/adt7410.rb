module Rgpio
  # An ADT7410 I2C temperature sensor (Analog Devices).
  #
  #   sensor = Rgpio::ADT7410.new
  #   puts sensor.temperature   # => 24.5  (degrees Celsius)
  #   sensor.close
  #
  # The address is set by the A1/A0 pins: 0x48 with both tied low (the default
  # on the common breakout boards), through 0x4b with both high.
  #
  # The sensor powers up in 13-bit mode, which resolves 0.0625 degC and is what
  # the datasheet calls the default; 16-bit mode resolves 0.0078 degC and is
  # selected with `resolution: 16`.
  class ADT7410
    DEFAULT_ADDRESS = 0x48

    # Register map (the subset this driver uses).
    REG_TEMPERATURE = 0x00
    REG_STATUS = 0x02
    REG_CONFIG = 0x03
    REG_ID = 0x0b

    # Configuration register bit 7 selects 16-bit resolution.
    CONFIG_RESOLUTION_16 = 0x80

    # Upper five bits of the ID register are the manufacturer ID; the lower
    # three are the silicon revision.
    MANUFACTURER_ID = 0b11001

    # Counts per degree Celsius, per resolution. In 13-bit mode the three low
    # bits of the register hold the Tcrit/Thigh/Tlow flags instead of data.
    COUNTS_PER_DEGREE = { 13 => 16.0, 16 => 128.0 }.freeze

    # The first conversion after power-up takes 240 ms; reading before it has
    # finished returns the 0 degC reset value rather than an error.
    CONVERSION_TIME = 0.24

    # @param address    [Integer] 7-bit address, 0x48..0x4b
    # @param bus        [Integer] i2c-dev bus number
    # @param resolution [Integer] 13 or 16 bits
    # @param i2c        [I2C, nil] an open device to share, or nil to open one
    def initialize(address: DEFAULT_ADDRESS, bus: I2C::DEFAULT_BUS, resolution: 13, i2c: nil)
      @owns_i2c = i2c.nil?
      @i2c = i2c || I2C.new(address: address, bus: bus)
      @closed = false
      self.resolution = resolution
    end

    # @return [I2C] the bus device this sensor is read through
    attr_reader :i2c

    # @return [Integer] 13 or 16
    attr_reader :resolution

    # @param bits [Integer] 13 or 16
    def resolution=(bits)
      raise ArgumentError, "resolution must be 13 or 16, got #{bits.inspect}" unless COUNTS_PER_DEGREE.key?(bits)

      config = @i2c.read_register(REG_CONFIG).first
      config = bits == 16 ? config | CONFIG_RESOLUTION_16 : config & ~CONFIG_RESOLUTION_16
      @i2c.write_register(REG_CONFIG, config & 0xff)
      @resolution = bits
    end

    # @return [Float] temperature in degrees Celsius
    def temperature
      msb, lsb = @i2c.read_register(REG_TEMPERATURE, 2)
      self.class.convert(msb, lsb, @resolution)
    end

    alias value temperature

    # @return [Array<Integer>] the raw two temperature bytes, MSB first
    def raw_temperature
      @i2c.read_register(REG_TEMPERATURE, 2)
    end

    # @return [Integer] the ID register: manufacturer ID in bits 7..3,
    #         silicon revision in bits 2..0
    def id
      @i2c.read_register(REG_ID).first
    end

    # A cheap "is the sensor really there" check for examples and diagnostics.
    # @return [Boolean] true when the ID register reports Analog Devices
    def detected?
      (id >> 3) == MANUFACTURER_ID
    rescue SystemCallError
      false
    end

    # Convert a raw register pair to degrees Celsius. Both resolutions are
    # two's complement, so a set sign bit means the reading is below 0 degC.
    # @return [Float]
    def self.convert(msb, lsb, resolution = 13)
      counts = COUNTS_PER_DEGREE.fetch(resolution)
      raw = ((msb << 8) | lsb)
      raw >>= 3 if resolution == 13
      sign_bit = resolution == 13 ? 0x1000 : 0x8000
      raw -= sign_bit * 2 if raw & sign_bit != 0
      raw / counts
    end

    # Close the bus device, but only if this sensor opened it.
    def close
      return if @closed

      @closed = true
      @i2c.close if @owns_i2c
    end

    def closed?
      @closed
    end
  end
end
