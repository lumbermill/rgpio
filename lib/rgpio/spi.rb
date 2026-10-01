require "fiddle"

module Rgpio
  # A device on a Linux spidev bus (/dev/spidevB.D).
  #
  # Like {I2C}, this is ioctl work on a character device, so it needs no
  # libgpiod and works even where Rgpio.available? is false.
  #
  # Usage (block form — recommended):
  #   Rgpio::SPI.open(bus: 0, device: 0, speed_hz: 1_000_000) do |spi|
  #     rx = spi.transfer([0x06, 0x00, 0x00])
  #   end
  #
  # SPI is full duplex: every transfer clocks the same number of bytes in each
  # direction, so {#transfer} always answers with as many bytes as it was given.
  # {#write} and {#read} are that same transfer with one direction ignored.
  #
  # The header bus is SPI0 (GPIO10 = MOSI, GPIO9 = MISO, GPIO11 = SCLK, GPIO8 =
  # CE0, GPIO7 = CE1), and only appears once it is enabled — see README for the
  # dtparam line.
  class SPI
    # ioctl numbers from <linux/spi/spidev.h>. They are built here rather than
    # written out so the derivation stays checkable: direction in bits 30-31,
    # payload size in 16-29, a 'k' magic in 8-15, and the request in 0-7.
    IOC_MAGIC = 0x6b
    IOC_WRITE = 1
    IOC_READ = 2

    # struct spi_ioc_transfer is { __u64 tx_buf; __u64 rx_buf; __u32 len;
    # __u32 speed_hz; __u16 delay_usecs; __u8 bits_per_word, cs_change,
    # tx_nbits, rx_nbits, word_delay_usecs, pad; } — exactly 32 bytes, and the
    # header promises the same layout in 32- and 64-bit userspace. The two
    # buffer fields are __u64 even where a pointer is 32 bits wide.
    TRANSFER_SIZE = 32

    DEFAULT_SPEED_HZ = 1_000_000
    DEFAULT_BITS_PER_WORD = 8

    # Clock polarity and phase, as the kernel numbers them.
    MODE_RANGE = (0..3)

    # Where spidev publishes the most it accepts in one message, and what that
    # is when the parameter cannot be read.
    BUFSIZ_PATH = "/sys/module/spidev/parameters/bufsiz".freeze
    DEFAULT_BUFSIZ = 4096

    # @return [Integer] the largest message spidev accepts, in bytes. A module
    #   parameter (spidev.bufsiz=), so it is the same for every bus.
    def self.max_transfer_size
      @max_transfer_size ||= begin
        size = File.read(BUFSIZ_PATH).to_i
        size.positive? ? size : DEFAULT_BUFSIZ
      rescue SystemCallError
        DEFAULT_BUFSIZ
      end
    end

    # @return [Integer] the ioctl request for a message of `count` transfers
    def self.message_ioctl(count)
      ioctl_number(IOC_WRITE, 0, TRANSFER_SIZE * count)
    end

    # @return [Integer] an encoded ioctl request
    def self.ioctl_number(direction, request, size)
      (direction << 30) | (size << 16) | (IOC_MAGIC << 8) | request
    end

    IOC_WR_MODE = ioctl_number(IOC_WRITE, 1, 1)
    IOC_RD_MODE = ioctl_number(IOC_READ, 1, 1)
    IOC_WR_LSB_FIRST = ioctl_number(IOC_WRITE, 2, 1)
    IOC_WR_BITS_PER_WORD = ioctl_number(IOC_WRITE, 3, 1)
    IOC_RD_BITS_PER_WORD = ioctl_number(IOC_READ, 3, 1)
    IOC_WR_MAX_SPEED_HZ = ioctl_number(IOC_WRITE, 4, 4)
    IOC_RD_MAX_SPEED_HZ = ioctl_number(IOC_READ, 4, 4)

    # Pack a struct spi_ioc_transfer. Kept at class level so the layout can be
    # checked without a bus present.
    # @return [String]
    def self.pack_transfer(tx_addr, rx_addr, len, speed_hz, bits_per_word: DEFAULT_BITS_PER_WORD,
                           delay_us: 0, cs_change: false)
      # "Q", not "J": the two address fields are __u64 even where a pointer is
      # only 32 bits wide.
      [tx_addr, rx_addr].pack("Q2") +
        [len, speed_hz].pack("LL") +
        [delay_us].pack("S") +
        [bits_per_word, cs_change ? 1 : 0, 0, 0, 0, 0].pack("C6")
    end

    # @return [Array<Array(Integer, Integer)>] [bus, device] of every spidev node
    def self.devices
      Dir.glob("/dev/spidev*").filter_map do |path|
        match = path.match(%r{/dev/spidev(\d+)\.(\d+)\z})
        [match[1].to_i, match[2].to_i] if match
      end.sort
    end

    # Open a device, yielding it and closing it afterwards when a block is given.
    # @return [SPI, Object] the device, or the block's value
    def self.open(**)
      spi = new(**)
      return spi unless block_given?

      begin
        yield spi
      ensure
        spi.close
      end
    end

    # @param bus           [Integer] spidev bus number; 0 is the 40-pin header
    # @param device        [Integer] chip-select index on that bus
    # @param speed_hz      [Integer] clock rate
    # @param mode          [Integer] 0..3, clock polarity and phase
    # @param bits_per_word [Integer] word size in bits
    def initialize(bus: 0, device: 0, speed_hz: DEFAULT_SPEED_HZ, mode: 0,
                   bits_per_word: DEFAULT_BITS_PER_WORD)
      @bus = bus
      @device = device
      @path = "/dev/spidev#{bus}.#{device}"
      unless File.exist?(@path)
        raise SPIError,
              "#{@path} not found. Enable the header bus with `dtparam=spi=on` in /boot/firmware/config.txt"
      end

      @io = File.open(@path, "r+b")
      @closed = false
      self.mode = mode
      self.bits_per_word = bits_per_word
      self.speed_hz = speed_hz
    end

    # @return [Integer] spidev bus number
    attr_reader :bus

    # @return [Integer] chip-select index
    attr_reader :device

    # @return [String] path of the bus character device
    attr_reader :path

    # @return [Integer] clock rate in Hz
    attr_reader :speed_hz

    # @return [Integer] 0..3
    attr_reader :mode

    # @return [Integer] word size in bits
    attr_reader :bits_per_word

    def speed_hz=(hz)
      raise ArgumentError, "speed_hz must be positive, got #{hz.inspect}" unless hz.is_a?(Integer) && hz.positive?

      @io.ioctl(IOC_WR_MAX_SPEED_HZ, [hz].pack("L"))
      @speed_hz = hz
    end

    def mode=(value)
      raise ArgumentError, "mode must be in #{MODE_RANGE}, got #{value.inspect}" unless MODE_RANGE.cover?(value)

      @io.ioctl(IOC_WR_MODE, [value].pack("C"))
      @mode = value
    end

    def bits_per_word=(bits)
      unless bits.is_a?(Integer) && bits.positive?
        raise ArgumentError,
              "bits_per_word must be positive, got #{bits.inspect}"
      end

      @io.ioctl(IOC_WR_BITS_PER_WORD, [bits].pack("C"))
      @bits_per_word = bits
    end

    # Clock bytes out and in at the same time.
    # @param bytes    [Array<Integer>, String] bytes to send
    # @param speed_hz [Integer, nil] override the clock for this transfer only
    # @param delay_us [Integer] hold the chip select this long afterwards
    # @return [Array<Integer>] the bytes that came back, one per byte sent
    def transfer(bytes, speed_hz: nil, delay_us: 0)
      out = Bytes.pack(bytes)
      raise ArgumentError, "transfer needs at least one byte" if out.empty?

      tx = buffer(out)
      rx = Fiddle::Pointer.malloc(out.bytesize, Fiddle::RUBY_FREE)
      message = self.class.pack_transfer(tx.to_i, rx.to_i, out.bytesize, speed_hz || @speed_hz,
                                         bits_per_word: @bits_per_word, delay_us: delay_us)
      @io.ioctl(self.class.message_ioctl(1), message)
      rx[0, out.bytesize].unpack("C*")
    end

    # Send bytes, ignoring what comes back.
    # @return [Integer] number of bytes sent
    def write(*bytes)
      transfer(bytes).size
    end

    # Send a block of any length, ignoring what comes back — for a display's
    # pixel data, where a frame is many times what spidev takes in one message.
    # The block goes out in messages of at most {.max_transfer_size} bytes, so
    # chip select is released between them; a controller that keys on chip
    # select rather than on a command (the ILI9341 does not) needs #transfer.
    # Nothing is unpacked on the way back, which keeps a frame cheap.
    # @param data [String] bytes to send
    # @return [Integer] number of bytes sent
    def send_bytes(data)
      data = data.b
      chunk = self.class.max_transfer_size
      @tx_buffer ||= Fiddle::Pointer.malloc(chunk, Fiddle::RUBY_FREE)
      (0...data.bytesize).step(chunk) do |offset|
        part = data.byteslice(offset, chunk)
        @tx_buffer[0, part.bytesize] = part
        message = self.class.pack_transfer(@tx_buffer.to_i, 0, part.bytesize, @speed_hz,
                                           bits_per_word: @bits_per_word)
        @io.ioctl(self.class.message_ioctl(1), message)
      end
      data.bytesize
    end

    # Clock in `count` bytes, sending zeros.
    # @return [Array<Integer>]
    def read(count)
      raise ArgumentError, "count must be positive, got #{count}" unless count.positive?

      transfer([0] * count)
    end

    def close
      return if @closed

      @closed = true
      @io.close
    end

    def closed?
      @closed
    end

    private

    def buffer(str)
      ptr = Fiddle::Pointer.malloc(str.bytesize, Fiddle::RUBY_FREE)
      ptr[0, str.bytesize] = str
      ptr
    end
  end
end
