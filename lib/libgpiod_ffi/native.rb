# frozen_string_literal: true

require "fiddle"
require "fiddle/import"

module LibgpiodFFI
  # Raw bindings to libgpiod v2, built on Ruby's stdlib `fiddle`.
  #
  # Why fiddle instead of the `ffi` gem: fiddle ships compiled together with
  # the Ruby interpreter, so it always matches the host architecture. The
  # precompiled `ffi` gem targets an ARMv7 baseline and crashes with an
  # "Illegal instruction" on ARMv6 boards (Pi Zero / Pi 1). libgpiod v2 is an
  # opaque-pointer API (callers never touch struct internals), so dropping ffi
  # costs us nothing here.
  #
  # Do not use this module directly — use Chip / LineRequest / HardwarePWM.
  module Native
    extend Fiddle::Importer

    # Try each soname in turn; stop at the first that loads (mirrors the old
    # `ffi_lib [...]` fallback). dlload raises Fiddle::DLError when a library
    # is missing.
    LIBRARY_AVAILABLE = ["libgpiod.so.3", "libgpiod.so.2", "libgpiod.so"].any? do |soname|
      dlload soname
      true
    rescue Fiddle::DLError
      false
    end

    # A NULL pointer (replaces FFI::Pointer::NULL).
    NULL = Fiddle::NULL

    # errno saved by the most recent native call (replaces FFI.errno).
    # @return [Integer]
    def self.errno
      Fiddle.last_error
    end

    # Allocate a native buffer holding an array of uint32 line offsets
    # (replaces FFI::MemoryPointer + put_array_of_uint32). The buffer owns its
    # memory and is freed when garbage-collected.
    # @param values [Array<Integer>]
    # @return [Fiddle::Pointer]
    def self.uint32_buffer(values)
      packed = values.pack("L*")
      ptr = Fiddle::Pointer.malloc(packed.bytesize, Fiddle::RUBY_FREE)
      ptr[0, packed.bytesize] = packed
      ptr
    end

    if LIBRARY_AVAILABLE
      # -----------------------------------------------------------------------
      # Direction enum values (gpiod_line_direction)
      # -----------------------------------------------------------------------
      LINE_DIRECTION_AS_IS  = 1
      LINE_DIRECTION_INPUT  = 2
      LINE_DIRECTION_OUTPUT = 3

      # -----------------------------------------------------------------------
      # Line value enum (gpiod_line_value)
      # -----------------------------------------------------------------------
      LINE_VALUE_ERROR    = -1
      LINE_VALUE_INACTIVE =  0
      LINE_VALUE_ACTIVE   =  1

      # -----------------------------------------------------------------------
      # Edge detection enum (gpiod_line_edge)
      # -----------------------------------------------------------------------
      LINE_EDGE_NONE    = 1
      LINE_EDGE_RISING  = 2
      LINE_EDGE_FALLING = 3
      LINE_EDGE_BOTH    = 4

      # -----------------------------------------------------------------------
      # Edge event type enum (gpiod_edge_event_type)
      # -----------------------------------------------------------------------
      EDGE_EVENT_RISING_EDGE  = 1
      EDGE_EVENT_FALLING_EDGE = 2

      # -----------------------------------------------------------------------
      # Bias enum (gpiod_line_bias)
      # -----------------------------------------------------------------------
      LINE_BIAS_AS_IS     = 1
      LINE_BIAS_UNKNOWN   = 2
      LINE_BIAS_DISABLED  = 3
      LINE_BIAS_PULL_UP   = 4
      LINE_BIAS_PULL_DOWN = 5

      # -----------------------------------------------------------------------
      # Version
      # -----------------------------------------------------------------------
      extern "const char *gpiod_api_version(void)"

      # -----------------------------------------------------------------------
      # Chip — gpiod_chip_*
      # -----------------------------------------------------------------------
      extern "void *gpiod_chip_open(const char *path)"
      extern "void gpiod_chip_close(void *chip)"

      # -----------------------------------------------------------------------
      # Chip info — gpiod_chip_info_*
      # -----------------------------------------------------------------------
      extern "void *gpiod_chip_get_info(void *chip)"
      extern "void gpiod_chip_info_free(void *info)"
      extern "const char *gpiod_chip_info_get_name(void *info)"
      extern "const char *gpiod_chip_info_get_label(void *info)"
      extern "size_t gpiod_chip_info_get_num_lines(void *info)"

      # -----------------------------------------------------------------------
      # Line settings — gpiod_line_settings_*
      # -----------------------------------------------------------------------
      extern "void *gpiod_line_settings_new(void)"
      extern "void gpiod_line_settings_free(void *settings)"
      extern "int gpiod_line_settings_set_direction(void *settings, int direction)"
      extern "int gpiod_line_settings_set_edge_detection(void *settings, int edge)"
      extern "int gpiod_line_settings_set_bias(void *settings, int bias)"
      # The C parameter is _Bool (1 byte). We declare it as int and pass 1/0
      # via the wrapper below; the callee reads the value as boolean.
      extern "void gpiod_line_settings_set_active_low(void *settings, int active_low)"
      extern "int gpiod_line_settings_set_output_value(void *settings, int value)"
      extern "int gpiod_line_settings_set_debounce_period_us(void *settings, unsigned long period_us)"

      # -----------------------------------------------------------------------
      # Line config — gpiod_line_config_*
      # offsets is const unsigned int* — pass a Native.uint32_buffer pointer.
      # -----------------------------------------------------------------------
      extern "void *gpiod_line_config_new(void)"
      extern "void gpiod_line_config_free(void *config)"
      extern "int gpiod_line_config_add_line_settings(void *config, void *offsets, size_t num_offsets, void *settings)"

      # -----------------------------------------------------------------------
      # Request config — gpiod_request_config_*
      # -----------------------------------------------------------------------
      extern "void *gpiod_request_config_new(void)"
      extern "void gpiod_request_config_free(void *config)"
      extern "void gpiod_request_config_set_consumer(void *config, const char *consumer)"

      # -----------------------------------------------------------------------
      # Line request — gpiod_chip_request_lines / gpiod_line_request_*
      # req_cfg may be NULL (pass Native::NULL).
      # -----------------------------------------------------------------------
      extern "void *gpiod_chip_request_lines(void *chip, void *req_cfg, void *line_cfg)"
      extern "void gpiod_line_request_release(void *request)"
      # Returns LINE_VALUE_ACTIVE / LINE_VALUE_INACTIVE / LINE_VALUE_ERROR
      extern "int gpiod_line_request_get_value(void *request, unsigned int offset)"
      # Returns 0 on success, -1 on error
      extern "int gpiod_line_request_set_value(void *request, unsigned int offset, int value)"

      # -----------------------------------------------------------------------
      # Edge event waiting / reading
      # timeout_ns: -1 = block forever, 0 = non-blocking, >0 = wait N ns
      # Returns: 1 (event ready), 0 (timeout), -1 (error)
      # -----------------------------------------------------------------------
      extern "int gpiod_line_request_wait_edge_events(void *request, int64_t timeout_ns)"
      # Returns number of events read, or -1 on error
      extern "int gpiod_line_request_read_edge_events(void *request, void *buffer)"

      # -----------------------------------------------------------------------
      # Edge event buffer — gpiod_edge_event_buffer_*
      # -----------------------------------------------------------------------
      extern "void *gpiod_edge_event_buffer_new(size_t capacity)"
      extern "void gpiod_edge_event_buffer_free(void *buffer)"
      extern "size_t gpiod_edge_event_buffer_get_num_events(void *buffer)"
      extern "void *gpiod_edge_event_buffer_get_event(void *buffer, unsigned long index)"

      # -----------------------------------------------------------------------
      # Edge event — gpiod_edge_event_*
      # -----------------------------------------------------------------------
      # Returns EDGE_EVENT_RISING_EDGE or EDGE_EVENT_FALLING_EDGE
      extern "int gpiod_edge_event_get_event_type(void *event)"
      extern "unsigned int gpiod_edge_event_get_line_offset(void *event)"
      extern "uint64_t gpiod_edge_event_get_timestamp_ns(void *event)"

      # -- Ruby-side conversion wrappers -------------------------------------

      # fiddle returns char* as a Fiddle::Pointer; convert to a Ruby String
      # (nil when NULL) to match the old FFI :string behavior.
      STRING_RETURNING = %i[
        gpiod_api_version
        gpiod_chip_info_get_name
        gpiod_chip_info_get_label
      ].freeze

      STRING_RETURNING.each do |meth|
        raw = :"#{meth}__ptr"
        singleton_class.send(:alias_method, raw, meth)
        singleton_class.send(:define_method, meth) do |*args|
          ptr = send(raw, *args)
          ptr.null? ? nil : ptr.to_s
        end
      end

      # Accept a Ruby boolean for active_low and pass it as 1/0.
      singleton_class.send(:alias_method, :gpiod_line_settings_set_active_low__int,
                           :gpiod_line_settings_set_active_low)
      singleton_class.send(:define_method, :gpiod_line_settings_set_active_low) do |settings, flag|
        gpiod_line_settings_set_active_low__int(settings, flag ? 1 : 0)
      end
    end
  end
end
