module Rgpio
  # 16-bit colour as colour TFT controllers take it: 5 bits red, 6 green,
  # 5 blue, sent high byte first.
  #
  #   Rgpio::RGB565.from(:orange)         # => 0xfd20
  #   Rgpio::RGB565.from([255, 128, 0])   # => 0xfc00
  #   Rgpio::RGB565.from(0x07e0)          # => 0x07e0
  module RGB565
    COLORS = {
      black: 0x0000,
      white: 0xffff,
      red: 0xf800,
      green: 0x07e0,
      blue: 0x001f,
      yellow: 0xffe0,
      cyan: 0x07ff,
      magenta: 0xf81f,
      orange: 0xfd20,
      gray: 0x8410,
      navy: 0x0010,
      maroon: 0x8000,
      olive: 0x8400,
      purple: 0x8010,
      teal: 0x0410,
      dark_green: 0x0400,
    }.freeze

    # @return [Integer] 8-bit red, green and blue packed as RGB565; the low
    #   bits that do not fit are dropped
    def self.pack(red, green, blue)
      [red, green, blue].each do |c|
        next if c.is_a?(Integer) && c.between?(0, 255)

        raise ArgumentError, "colour components must be in 0..255, got #{c.inspect}"
      end
      ((red & 0xf8) << 8) | ((green & 0xfc) << 3) | (blue >> 3)
    end

    # @param value [Symbol, String, Array<Integer>, Integer] a name from
    #   {COLORS}, an [r, g, b] triple of 0..255, or an RGB565 Integer
    # @return [Integer] the colour as RGB565
    def self.from(value)
      case value
      when Symbol, String
        COLORS.fetch(value.to_sym) do
          raise ArgumentError, "unknown colour #{value.inspect}; one of #{COLORS.keys.join(", ")}"
        end
      when Array
        raise ArgumentError, "a colour array is [r, g, b], got #{value.inspect}" unless value.size == 3

        pack(*value)
      when Integer
        raise ArgumentError, "an RGB565 colour is in 0..0xffff, got #{value}" unless value.between?(0, 0xffff)

        value
      else
        raise ArgumentError, "colour must be a name, [r, g, b] or an RGB565 Integer, got #{value.inspect}"
      end
    end
  end
end
