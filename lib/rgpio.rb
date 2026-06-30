# frozen_string_literal: true

require_relative "rgpio/version"
require_relative "rgpio/native"
require_relative "rgpio/chip"
require_relative "rgpio/line_request"
require_relative "rgpio/pwm"

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
module Rgpio
  # Raised for gem-level errors not covered by stdlib Errno classes.
  class Error < StandardError; end

  # Raised when libgpiod shared library cannot be loaded on the current system.
  class NotAvailableError < Error; end

  # Raised for PWM-related errors.
  class PWMError < Error; end

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
end
