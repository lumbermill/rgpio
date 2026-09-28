module Rgpio
  # Turning argument lists into the bytes that go on a bus. Shared by {I2C} and
  # {SPI} so that `write(0x40, "Hi")` and `write(0x40, 0x48, 0x69)` mean the same
  # thing on both.
  module Bytes
    # @param bytes [Array<Integer, String, Array>]
    # @return [String] binary string
    def self.pack(bytes)
      Array(bytes).flatten.map { |b| b.is_a?(String) ? b.b : [b].pack("C") }.join
    end
  end
end
