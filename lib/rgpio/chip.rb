# frozen_string_literal: true

module Rgpio
  # Represents an open GPIO chip (e.g. /dev/gpiochip0).
  #
  # Usage (block form — recommended, ensures close on exit):
  #   # Auto-detect the GPIO controller wired to the 40-pin header
  #   # (works on Pi 5 / Pi 4 / Pi Zero without code changes):
  #   Rgpio::Chip.open do |chip|
  #     request = chip.request_lines(offsets: [17], direction: :output)
  #     # ...
  #   end
  #
  #   # Or open a specific device explicitly:
  #   Rgpio::Chip.open("/dev/gpiochip0") { |chip| ... }
  #
  # Usage (manual):
  #   chip = Rgpio::Chip.new        # auto-detect
  #   # ...
  #   chip.close
  class Chip
    # Glob matching every GPIO character device exposed by the kernel.
    DEVICE_GLOB = "/dev/gpiochip*"

    # Labels of the GPIO controller wired to the 40-pin header, in detection
    # priority order (newest SoC first). The label comes from the chip's
    # info record (gpiod_chip_info_get_label) and is stable per SoC family:
    #
    #   pinctrl-rp1     → Raspberry Pi 5 (RP1 I/O controller)
    #   pinctrl-bcm2711 → Raspberry Pi 4 / 400
    #   pinctrl-bcm2835 → Pi Zero / Zero W / Zero 2 W / Pi 1 / 2 / 3
    #
    # On Pi 5 the SoC also exposes several "gpio-brcmstb@..." chips that are
    # NOT on the header — matching by label avoids selecting those.
    HEADER_CHIP_LABELS = %w[
      pinctrl-rp1
      pinctrl-bcm2711
      pinctrl-bcm2835
    ].freeze

    # @param path [String, nil] path to the GPIO chip device. When nil
    #   (the default), the header GPIO controller is auto-detected.
    def initialize(path = nil)
      Rgpio.assert_available!
      @path = path || self.class.detect_path
      @chip_ptr = Native.gpiod_chip_open(@path)
      if @chip_ptr.null?
        raise SystemCallError.new("gpiod_chip_open(#{@path})", Native.errno)
      end
    end

    # Open a chip, yield it to the block, then close it.
    # With no path, auto-detects the header GPIO controller.
    def self.open(path = nil, &block)
      chip = new(path)
      block.call(chip)
    ensure
      chip&.close
    end

    # Enumerate every GPIO chip present on the system.
    #
    # @return [Array<Hash>] one entry per chip, sorted by device index:
    #   { path:, name:, label:, num_lines: }
    def self.list
      Rgpio.assert_available!
      Dir.glob(DEVICE_GLOB).sort_by { |p| device_index(p) }.filter_map do |path|
        chip = new(path)
        begin
          { path: path, name: chip.name, label: chip.label, num_lines: chip.num_lines }
        ensure
          chip.close
        end
      rescue SystemCallError
        # Skip chips we cannot open (e.g. permissions, races) rather than abort.
        nil
      end
    end

    # Resolve the device path of the GPIO controller wired to the 40-pin
    # header. Pass `chips` to test the selection logic without hardware.
    #
    # @param chips [Array<Hash>] chip records as returned by {.list}
    # @return [String] device path (e.g. "/dev/gpiochip0")
    # @raise [NotAvailableError] when no usable GPIO chip is found
    def self.detect_path(chips = list)
      if chips.empty?
        raise NotAvailableError,
              "No GPIO chips found under #{DEVICE_GLOB}. Is this a Raspberry Pi?"
      end
      select_header_chip(chips).fetch(:path)
    end

    # Pick the header GPIO controller from a list of chip records.
    # Prefers a known SoC label; falls back to the chip with the most lines
    # (the header controller is, in practice, the largest one).
    #
    # @param chips [Array<Hash>] chip records as returned by {.list}
    # @return [Hash] the selected chip record
    def self.select_header_chip(chips)
      HEADER_CHIP_LABELS.each do |label|
        match = chips.find { |c| c[:label] == label }
        return match if match
      end
      chips.max_by { |c| c[:num_lines] }
    end

    # Numeric index of a gpiochip device path ("/dev/gpiochip10" → 10),
    # so chips sort numerically rather than lexically.
    def self.device_index(path)
      File.basename(path).delete_prefix("gpiochip").to_i
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
    # @param debounce_us [Integer] kernel-level debounce period in microseconds
    #                    (0 = disabled). Suppresses bounces shorter than this window.
    #                    Typical value for mechanical buttons: 5_000 (5 ms).
    # @param initial_value [:active, :inactive] initial output value
    #                       (only meaningful when direction is :output)
    # @param consumer [String] name shown in kernel request list (optional)
    # @return [LineRequest]
    def request_lines(offsets:, direction:, edge: :none, bias: :as_is,
                      active_low: false, debounce_us: 0, initial_value: :inactive, consumer: nil)
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
        if debounce_us && debounce_us > 0
          check! Native.gpiod_line_settings_set_debounce_period_us(settings_ptr, debounce_us),
                 "gpiod_line_settings_set_debounce_period_us"
        end
        if direction == :output
          check! Native.gpiod_line_settings_set_output_value(
                   settings_ptr, initial_value == :active ? Native::LINE_VALUE_ACTIVE : Native::LINE_VALUE_INACTIVE
                 ), "gpiod_line_settings_set_output_value"
        end

        line_config_ptr = Native.gpiod_line_config_new
        raise Error, "gpiod_line_config_new failed" if line_config_ptr.null?

        begin
          offsets_arr = Array(offsets)
          offsets_ptr = Native.uint32_buffer(offsets_arr)

          check! Native.gpiod_line_config_add_line_settings(
                   line_config_ptr, offsets_ptr, offsets_arr.size, settings_ptr
                 ), "gpiod_line_config_add_line_settings"

          req_config_ptr = build_request_config(consumer)
          begin
            request_ptr = Native.gpiod_chip_request_lines(@chip_ptr, req_config_ptr, line_config_ptr)
            if request_ptr.null?
              raise SystemCallError.new("gpiod_chip_request_lines", Native.errno)
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
      raise SystemCallError.new("gpiod_chip_get_info", Native.errno) if info.null?
      begin
        yield info
      ensure
        Native.gpiod_chip_info_free(info)
      end
    end

    def build_request_config(consumer)
      ptr = Native.gpiod_request_config_new
      return Native::NULL if ptr.null?
      Native.gpiod_request_config_set_consumer(ptr, consumer) if consumer
      ptr
    end

    def check!(ret, fn_name)
      raise SystemCallError.new(fn_name, Native.errno) if ret == -1
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
