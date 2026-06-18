# frozen_string_literal: true

module LibgpiodFFI
  # Represents an open GPIO chip (e.g. /dev/gpiochip0).
  #
  # Usage (block form — recommended, ensures close on exit):
  #   LibgpiodFFI::Chip.open("/dev/gpiochip0") do |chip|
  #     request = chip.request_lines(offsets: [17], direction: :output)
  #     # ...
  #   end
  #
  # Usage (manual):
  #   chip = LibgpiodFFI::Chip.new("/dev/gpiochip0")
  #   # ...
  #   chip.close
  class Chip
    DEFAULT_PATH = "/dev/gpiochip0"

    # @param path [String] path to the GPIO chip device (default: /dev/gpiochip0)
    def initialize(path = DEFAULT_PATH)
      LibgpiodFFI.assert_available!
      @path = path
      @chip_ptr = Native.gpiod_chip_open(path)
      if @chip_ptr.null?
        raise SystemCallError.new("gpiod_chip_open(#{path})", FFI.errno)
      end
    end

    # Open a chip, yield it to the block, then close it.
    def self.open(path = DEFAULT_PATH, &block)
      chip = new(path)
      block.call(chip)
    ensure
      chip&.close
    end

    # @return [String] device path this chip was opened with
    attr_reader :path

    # @return [String] kernel name of the chip (e.g. "gpiochip0")
    def name
      with_info { |info| Native.gpiod_chip_info_get_name(info) }
    end

    # @return [String] label identifying the GPIO controller
    #   (e.g. "pinctrl-rp1" on Raspberry Pi 5)
    def label
      with_info { |info| Native.gpiod_chip_info_get_label(info) }
    end

    # @return [Integer] total number of GPIO lines on this chip
    def num_lines
      with_info { |info| Native.gpiod_chip_info_get_num_lines(info) }
    end

    # Request one or more lines for exclusive use.
    #
    # @param offsets  [Array<Integer>] GPIO line offsets to request
    # @param direction [:input, :output] line direction
    # @param edge      [:none, :rising, :falling, :both] edge detection
    #                  (only meaningful when direction is :input)
    # @param bias      [:as_is, :disabled, :pull_up, :pull_down]
    # @param active_low [Boolean] invert active/inactive logic
    # @param initial_value [:active, :inactive] initial output value
    #                       (only meaningful when direction is :output)
    # @param consumer [String] name shown in kernel request list (optional)
    # @return [LineRequest]
    def request_lines(offsets:, direction:, edge: :none, bias: :as_is,
                      active_low: false, initial_value: :inactive, consumer: nil)
      assert_open!

      settings_ptr = Native.gpiod_line_settings_new
      raise Error, "gpiod_line_settings_new failed" if settings_ptr.null?

      begin
        check! Native.gpiod_line_settings_set_direction(settings_ptr, direction_value(direction)),
               "gpiod_line_settings_set_direction"
        check! Native.gpiod_line_settings_set_edge_detection(settings_ptr, edge_value(edge)),
               "gpiod_line_settings_set_edge_detection"
        check! Native.gpiod_line_settings_set_bias(settings_ptr, bias_value(bias)),
               "gpiod_line_settings_set_bias"
        Native.gpiod_line_settings_set_active_low(settings_ptr, active_low)
        if direction == :output
          check! Native.gpiod_line_settings_set_output_value(
                   settings_ptr, initial_value == :active ? Native::LINE_VALUE_ACTIVE : Native::LINE_VALUE_INACTIVE
                 ), "gpiod_line_settings_set_output_value"
        end

        line_config_ptr = Native.gpiod_line_config_new
        raise Error, "gpiod_line_config_new failed" if line_config_ptr.null?

        begin
          offsets_arr = Array(offsets)
          offsets_ptr = FFI::MemoryPointer.new(:uint32, offsets_arr.size)
          offsets_ptr.put_array_of_uint32(0, offsets_arr)

          check! Native.gpiod_line_config_add_line_settings(
                   line_config_ptr, offsets_ptr, offsets_arr.size, settings_ptr
                 ), "gpiod_line_config_add_line_settings"

          req_config_ptr = build_request_config(consumer)
          begin
            request_ptr = Native.gpiod_chip_request_lines(@chip_ptr, req_config_ptr, line_config_ptr)
            if request_ptr.null?
              raise SystemCallError.new("gpiod_chip_request_lines", FFI.errno)
            end
            LineRequest.new(request_ptr, offsets_arr)
          ensure
            Native.gpiod_request_config_free(req_config_ptr) unless req_config_ptr.null?
          end
        ensure
          Native.gpiod_line_config_free(line_config_ptr)
        end
      ensure
        Native.gpiod_line_settings_free(settings_ptr)
      end
    end

    # Close the chip and release all kernel resources.
    # Safe to call multiple times.
    def close
      return unless @chip_ptr && !@chip_ptr.null?
      Native.gpiod_chip_close(@chip_ptr)
      @chip_ptr = nil
    end

    def closed?
      @chip_ptr.nil?
    end

    private

    def assert_open!
      raise Error, "Chip is already closed" if closed?
    end

    def with_info
      assert_open!
      info = Native.gpiod_chip_get_info(@chip_ptr)
      raise SystemCallError.new("gpiod_chip_get_info", FFI.errno) if info.null?
      begin
        yield info
      ensure
        Native.gpiod_chip_info_free(info)
      end
    end

    def build_request_config(consumer)
      ptr = Native.gpiod_request_config_new
      return FFI::Pointer::NULL if ptr.null?
      Native.gpiod_request_config_set_consumer(ptr, consumer) if consumer
      ptr
    end

    def check!(ret, fn_name)
      raise SystemCallError.new(fn_name, FFI.errno) if ret == -1
    end

    def direction_value(sym)
      case sym
      when :as_is  then Native::LINE_DIRECTION_AS_IS
      when :input  then Native::LINE_DIRECTION_INPUT
      when :output then Native::LINE_DIRECTION_OUTPUT
      else raise ArgumentError, "Unknown direction: #{sym.inspect}"
      end
    end

    def edge_value(sym)
      case sym
      when :none    then Native::LINE_EDGE_NONE
      when :rising  then Native::LINE_EDGE_RISING
      when :falling then Native::LINE_EDGE_FALLING
      when :both    then Native::LINE_EDGE_BOTH
      else raise ArgumentError, "Unknown edge: #{sym.inspect}"
      end
    end

    def bias_value(sym)
      case sym
      when :as_is      then Native::LINE_BIAS_AS_IS
      when :disabled   then Native::LINE_BIAS_DISABLED
      when :pull_up    then Native::LINE_BIAS_PULL_UP
      when :pull_down  then Native::LINE_BIAS_PULL_DOWN
      else raise ArgumentError, "Unknown bias: #{sym.inspect}"
      end
    end
  end
end
