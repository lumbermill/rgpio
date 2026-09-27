require_relative "rgpio/version"
require_relative "rgpio/native"
require_relative "rgpio/chip"
require_relative "rgpio/line_request"
require_relative "rgpio/pwm"
require_relative "rgpio/software_pwm"
require_relative "rgpio/i2c"
require_relative "rgpio/devices/device"
require_relative "rgpio/devices/output_device"
require_relative "rgpio/devices/input_device"
require_relative "rgpio/devices/motor"
require_relative "rgpio/devices/pwm_channel"
require_relative "rgpio/devices/pwm_output_device"
require_relative "rgpio/devices/rgb_led"
require_relative "rgpio/devices/servo"
require_relative "rgpio/devices/adt7410"
require_relative "rgpio/devices/st7032"

# Ruby bindings for libgpiod v2 (Linux GPIO character device), bound through
# the stdlib `fiddle`. Targets Debian Trixie (libgpiod >= 2.1) on Raspberry Pi.
#
# Quick start — GPIO output:
#   Rgpio::Chip.open do |chip|
#     req = chip.request_lines(offsets: [17], direction: :output, consumer: "led")
#     req.set_value(17, :active)
#     sleep 1
#     req.set_value(17, :inactive)
#     req.release
#   end
#
# Quick start — Hardware PWM (servo):
#   Rgpio::HardwarePWM.open(gpio: 18) do |pwm|
#     pwm.frequency  = 50
#     pwm.duty_cycle = 0.075
#     pwm.enable
#     sleep 2
#   end
#
# Quick start — high-level devices:
#   led = Rgpio::LED.new(4)
#   led.on
#
#   button = Rgpio::Button.new(17)
#   button.when_pressed { puts "Pressed" }
#   Rgpio.pause
#
# Quick start — I2C devices:
#   puts Rgpio::ADT7410.new.temperature
#
#   lcd = Rgpio::ST7032.new
#   lcd.message = "Hello\nrgpio"
module Rgpio
  # Raised for gem-level errors not covered by stdlib Errno classes.
  class Error < StandardError; end

  # Raised when libgpiod shared library cannot be loaded on the current system.
  class NotAvailableError < Error; end

  # Raised for PWM-related errors.
  class PWMError < Error; end

  # Raised for I2C-related errors not reported as an Errno by the kernel.
  class I2CError < Error; end

  # @return [Boolean] whether the libgpiod shared library is loaded
  def self.available?
    Native::LIBRARY_AVAILABLE
  end

  # Raise NotAvailableError unless libgpiod is loaded.
  def self.assert_available!
    return if available?

    raise NotAvailableError,
          "libgpiod shared library not found. " \
          "Install on Debian/Raspbian: sudo apt install libgpiod3"
  end

  # @return [String, nil] libgpiod version string (e.g. "2.1.3"), or nil if unavailable
  def self.version
    return nil unless available?

    Native.gpiod_api_version
  end

  # Block the main thread until Ctrl-C, letting device callbacks run.
  # The Ruby counterpart of Python's signal.pause().
  def self.pause
    sleep
  rescue Interrupt
    nil
  end
end
