require "fiddle"

module Rgpio
  # An I2C device on a Linux i2c-dev bus (/dev/i2c-N).
  #
  # No libgpiod involved: the kernel exposes the whole bus through a character
  # device, so this works even where Rgpio.available? is false.
  #
  # Usage (block form — recommended):
  #   Rgpio::I2C.open(address: 0x48) do |i2c|
  #     msb, lsb = i2c.read_register(0x00, 2)
  #   end
  #
  # Usage (manual):
  #   i2c = Rgpio::I2C.new(address: 0x3e)
  #   i2c.write(0x00, 0x38)
  #   i2c.close
  #
  # The I2C bus on the 40-pin header (GPIO2 = SDA, GPIO3 = SCL) is bus 1, and
  # only appears once it is enabled — see docs/guide.md for the dtparam line.
  class I2C
    # ioctl numbers from <linux/i2c-dev.h>.
    I2C_SLAVE = 0x0703
    I2C_SLAVE_FORCE = 0x0706
    I2C_RDWR = 0x0707

    # i2c_msg flag: this message is a read (from <linux/i2c.h>).
    I2C_M_RD = 0x0001

    # The 40-pin header bus. Bus 0 exists on some boards but is reserved for
    # HAT EEPROMs and camera/display peripherals.
    DEFAULT_BUS = 1

    # Valid 7-bit addressing range: below 0x08 and above 0x77 is reserved.
    ADDRESS_RANGE = (0x08..0x77)

    # struct i2c_msg is { __u16 addr; __u16 flags; __u16 len; __u8 *buf; }:
    # three shorts, then the pointer on its natural alignment (offset 8 on both
    # 32- and 64-bit ARM, since the shorts are padded out to it).
    MSG_BUF_OFFSET = 8
    MSG_SIZE = MSG_BUF_OFFSET + Fiddle::SIZEOF_VOIDP

    # struct i2c_rdwr_ioctl_data is { struct i2c_msg *msgs; __u32 nmsgs; },
    # rounded up to pointer alignment.
    RDWR_SIZE = Fiddle::SIZEOF_VOIDP * 2

    # Pack a struct i2c_msg. Kept at class level so the layout can be checked
    # without a bus present.
    # @param buf_addr [Integer] address of the message's data buffer
    # @return [String]
    def self.pack_msg(address, flags, len, buf_addr)
      [address, flags, len].pack("SSS").ljust(MSG_BUF_OFFSET, "\0") + [buf_addr].pack("J")
    end

    # Pack a struct i2c_rdwr_ioctl_data pointing at `count` messages.
    # @param msgs_addr [Integer] address of the message array
    # @return [String]
    def self.pack_rdwr(msgs_addr, count)
      ([msgs_addr].pack("J") + [count].pack("L")).ljust(RDWR_SIZE, "\0")
    end

    # @return [Array<Integer>] bus numbers with a /dev/i2c-N node, ascending
    def self.buses
      Dir.glob("/dev/i2c-*").filter_map { |path| path[%r{/dev/i2c-(\d+)\z}, 1]&.to_i }.sort
    end

    # Open a device, yielding it and closing it afterwards when a block is given.
    # @return [I2C, Object] the device, or the block's value
    def self.open(address:, bus: DEFAULT_BUS)
      i2c = new(address: address, bus: bus)
      return i2c unless block_given?

      begin
        yield i2c
      ensure
        i2c.close
      end
    end

    # @param address [Integer] 7-bit device address (e.g. 0x48)
    # @param bus     [Integer] i2c-dev bus number; 1 is the 40-pin header
    # @param force   [Boolean] claim the address even if a kernel driver holds it
    def initialize(address:, bus: DEFAULT_BUS, force: false)
      unless ADDRESS_RANGE.cover?(address)
        raise ArgumentError,
              format("address must be in 0x%02x..0x%02x, got 0x%02x", ADDRESS_RANGE.first, ADDRESS_RANGE.last, address)
      end

      @address = address
      @bus = bus
      @path = "/dev/i2c-#{bus}"
      unless File.exist?(@path)
        raise I2CError,
              "#{@path} not found. Enable the header bus with `dtparam=i2c_arm=on` in /boot/firmware/config.txt"
      end

      @io = File.open(@path, "r+b")
      @io.ioctl(force ? I2C_SLAVE_FORCE : I2C_SLAVE, @address)
      @closed = false
    end

    # @return [Integer] 7-bit device address
    attr_reader :address

    # @return [Integer] i2c-dev bus number
    attr_reader :bus

    # @return [String] path of the bus character device
    attr_reader :path

    # Write bytes in a single transaction.
    # @param bytes [Array<Integer>, String] byte values, or a packed String
    # @return [Integer] number of bytes written
    def write(*bytes)
      @io.syswrite(Bytes.pack(bytes))
    end

    # Read bytes in a single transaction.
    # @param count [Integer] how many bytes to read
    # @return [Array<Integer>]
    def read(count)
      @io.sysread(count).unpack("C*")
    end

    # Write, then read without releasing the bus (repeated START). Devices with
    # an address pointer need this: a STOP between the two halves lets another
    # master move the pointer in between.
    # @param bytes [Array<Integer>, String] bytes to write first
    # @param count [Integer] how many bytes to read back
    # @return [Array<Integer>]
    def write_read(bytes, count)
      out = Bytes.pack(bytes)
      raise ArgumentError, "write_read needs at least one byte to write" if out.empty?
      raise ArgumentError, "count must be positive, got #{count}" unless count.positive?

      wbuf = buffer(out)
      rbuf = Fiddle::Pointer.malloc(count, Fiddle::RUBY_FREE)
      msgs = buffer(self.class.pack_msg(@address, 0, out.bytesize, wbuf.to_i) +
                    self.class.pack_msg(@address, I2C_M_RD, count, rbuf.to_i))
      @io.ioctl(I2C_RDWR, self.class.pack_rdwr(msgs.to_i, 2))
      rbuf[0, count].unpack("C*")
    end

    # Read `count` bytes from a register, addressing it with a repeated START.
    # @return [Array<Integer>]
    def read_register(register, count = 1)
      write_read([register], count)
    end

    # Write bytes to a register in one transaction.
    # @return [Integer] number of bytes written
    def write_register(register, *bytes)
      write(register, *bytes)
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
