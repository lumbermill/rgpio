require "fiddle"

module Rgpio
  # Turning argument lists into the bytes that go on a bus, and bytes into the
  # native memory a kernel call reads them from. Shared by {I2C} and
  # {SPI} so that `write(0x40, "Hi")` and `write(0x40, 0x48, 0x69)` mean the same
  # thing on both.
  module Bytes
    # All integers — the common case, and the large one (a display's pixels)
    # — go through a single pack: one String per byte cost 95 ms for 4096
    # bytes on a Pi Zero, against 4 ms this way.
    # @param bytes [Array<Integer, String, Array>]
    # @return [String] binary string
    def self.pack(bytes)
      items = Array(bytes).flatten
      return items.pack("C*") if items.none?(String)

      items.map { |b| b.is_a?(String) ? b.b : [b].pack("C") }.join.b
    end

    # Copy a string into freshly allocated native memory, freed when the
    # pointer is garbage-collected.
    # @param data [String]
    # @return [Fiddle::Pointer]
    def self.pointer(data)
      ptr = Fiddle::Pointer.malloc(data.bytesize, Fiddle::RUBY_FREE)
      ptr[0, data.bytesize] = data
      ptr
    end
  end
end
