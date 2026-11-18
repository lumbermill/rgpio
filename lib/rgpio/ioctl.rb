module Rgpio
  # Encoding of Linux ioctl request numbers, as the kernel's _IOC macro builds
  # them (<asm-generic/ioctl.h>): direction in bits 30-31, argument size in
  # 16-29, the driver's magic ("type") in 8-15 and the request number in 0-7.
  # Shared by {LineRequest} (GPIO, magic 0xB4) and {SPI} (spidev, magic 'k').
  module Ioctl
    NONE = 0
    WRITE = 1
    READ = 2
    READ_WRITE = 3

    # @return [Integer] an encoded ioctl request
    def self.number(direction, magic, request, size)
      (direction << 30) | (size << 16) | (magic << 8) | request
    end
  end
end
