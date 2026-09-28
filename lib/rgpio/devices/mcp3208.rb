module Rgpio
  # An MCP3208 analogue-to-digital converter: eight 12-bit channels over SPI.
  #
  #   adc = Rgpio::MCP3208.new
  #   adc.read(0)      # => 0..4095, the raw code
  #   adc.voltage(0)   # => volts, against the reference
  #   adc.close
  #
  # Wiring is SPI plus a reference: VDD and VREF to 3.3 V, AGND and DGND to
  # ground, CLK/DOUT/DIN to SCLK/MISO/MOSI, CS to CE0.
  #
  # The MCP3204 is the same part with four channels and the same protocol, so it
  # works through this class with `channels: 4`.
  #
  # Clock rate matters for correctness, not just speed: the datasheet allows
  # 1 MHz at 2.7 V and 2 MHz at 5 V, and a converter clocked past its sampling
  # rate returns values that look plausible and are wrong. The 1 MHz default is
  # inside the envelope for a 3.3 V supply.
  class MCP3208
    DEFAULT_CHANNELS = 8

    # 12 bits, so 4096 codes: code 4095 means the input is at the reference.
    RESOLUTION = 4096

    DEFAULT_REFERENCE_VOLTAGE = 3.3
    DEFAULT_SPEED_HZ = 1_000_000

    # First command byte: a start bit, then SGL/DIFF, then the top channel bit.
    START_SINGLE = 0x06
    START_DIFFERENTIAL = 0x04

    # @param channels          [Integer] 8 for an MCP3208, 4 for an MCP3204
    # @param reference_voltage [Float] volts on the VREF pin
    # @param bus               [Integer] spidev bus number
    # @param device            [Integer] chip-select index
    # @param speed_hz          [Integer] clock rate
    # @param spi               [SPI, nil] an open bus device to share, or nil to open one
    def initialize(channels: DEFAULT_CHANNELS, reference_voltage: DEFAULT_REFERENCE_VOLTAGE,
                   bus: 0, device: 0, speed_hz: DEFAULT_SPEED_HZ, spi: nil)
      @channels = channels
      @reference_voltage = reference_voltage.to_f
      @owns_spi = spi.nil?
      @spi = spi || SPI.new(bus: bus, device: device, speed_hz: speed_hz, mode: 0)
      @closed = false
    end

    # @return [SPI] the bus device readings go through
    attr_reader :spi

    # @return [Integer] how many input channels this part has
    attr_reader :channels

    # @return [Float] volts on the VREF pin
    attr_reader :reference_voltage

    # Read one channel.
    # @param channel      [Integer] 0...channels
    # @param differential [Boolean] measure the channel pair rather than the
    #                     single input: 0/1, 2/3, 4/5, 6/7, with the even channel
    #                     as IN+ when `channel` is even
    # @return [Integer] the raw code, 0..4095
    def read(channel, differential: false)
      raise Error, "MCP3208 is closed" if @closed
      unless channel.is_a?(Integer) && (0...@channels).cover?(channel)
        raise ArgumentError, "channel must be in 0...#{@channels}, got #{channel.inspect}"
      end

      start = differential ? START_DIFFERENTIAL : START_SINGLE
      received = @spi.transfer([start | ((channel & 0x04) >> 2), (channel & 0x03) << 6, 0x00])
      # The conversion arrives across the last two bytes: four null bits, then
      # the twelve data bits, most significant first.
      ((received[1] & 0x0f) << 8) | received[2]
    end

    # @return [Float] the channel as a fraction of the reference, 0.0..1.0
    def value(channel, differential: false)
      read(channel, differential: differential) / (RESOLUTION - 1).to_f
    end

    # @return [Float] the channel in volts
    def voltage(channel, differential: false)
      value(channel, differential: differential) * @reference_voltage
    end

    # Read every channel in turn. Not simultaneous — the part has one converter
    # behind a multiplexer, so these are consecutive samples.
    # @return [Array<Integer>] raw codes, channel 0 first
    def read_all
      Array.new(@channels) { |channel| read(channel) }
    end

    # Close the bus device, but only if this converter opened it.
    def close
      return if @closed

      @closed = true
      @spi.close if @owns_spi
    end

    def closed?
      @closed
    end
  end
end
