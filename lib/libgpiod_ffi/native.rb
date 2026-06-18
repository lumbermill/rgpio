# frozen_string_literal: true

require "ffi"

module LibgpiodFFI
  # Raw FFI bindings to libgpiod v2.
  # Targets libgpiod >= 2.1 (available in Debian Trixie as libgpiod2).
  # Do not use this module directly — use Chip / LineRequest / HardwarePWM instead.
  module Native
    extend FFI::Library

    LIBRARY_AVAILABLE = begin
      ffi_lib "gpiod"
      true
    rescue LoadError
      false
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
      LINE_BIAS_DISABLED  = 2
      LINE_BIAS_PULL_UP   = 3
      LINE_BIAS_PULL_DOWN = 4

      # -----------------------------------------------------------------------
      # Version
      # -----------------------------------------------------------------------
      attach_function :gpiod_version_string, [], :string

      # -----------------------------------------------------------------------
      # Chip — gpiod_chip_*
      # -----------------------------------------------------------------------
      attach_function :gpiod_chip_open,  [:string],  :pointer
      attach_function :gpiod_chip_close, [:pointer], :void

      # -----------------------------------------------------------------------
      # Chip info — gpiod_chip_info_*
      # -----------------------------------------------------------------------
      attach_function :gpiod_chip_get_info,          [:pointer], :pointer
      attach_function :gpiod_chip_info_free,         [:pointer], :void
      attach_function :gpiod_chip_info_get_name,     [:pointer], :string
      attach_function :gpiod_chip_info_get_label,    [:pointer], :string
      attach_function :gpiod_chip_info_get_num_lines, [:pointer], :size_t

      # -----------------------------------------------------------------------
      # Line settings — gpiod_line_settings_*
      # -----------------------------------------------------------------------
      attach_function :gpiod_line_settings_new,              [],                 :pointer
      attach_function :gpiod_line_settings_free,             [:pointer],         :void
      attach_function :gpiod_line_settings_set_direction,    [:pointer, :int],   :int
      attach_function :gpiod_line_settings_set_edge_detection, [:pointer, :int], :int
      attach_function :gpiod_line_settings_set_bias,         [:pointer, :int],   :int
      # active_low: C bool — ffi maps :bool to uint8 (stdbool.h _Bool)
      attach_function :gpiod_line_settings_set_active_low,   [:pointer, :bool],  :int
      attach_function :gpiod_line_settings_set_output_value, [:pointer, :int],   :int

      # -----------------------------------------------------------------------
      # Line config — gpiod_line_config_*
      # offsets param is const unsigned int* — pass FFI::MemoryPointer(:uint32)
      # -----------------------------------------------------------------------
      attach_function :gpiod_line_config_new,  [],                                       :pointer
      attach_function :gpiod_line_config_free, [:pointer],                               :void
      attach_function :gpiod_line_config_add_line_settings,
                      [:pointer, :pointer, :size_t, :pointer], :int

      # -----------------------------------------------------------------------
      # Request config — gpiod_request_config_*
      # -----------------------------------------------------------------------
      attach_function :gpiod_request_config_new,          [],                :pointer
      attach_function :gpiod_request_config_free,         [:pointer],        :void
      attach_function :gpiod_request_config_set_consumer, [:pointer, :string], :void

      # -----------------------------------------------------------------------
      # Line request — gpiod_chip_request_lines / gpiod_line_request_*
      # -----------------------------------------------------------------------
      # req_cfg may be NULL (pass FFI::Pointer::NULL)
      attach_function :gpiod_chip_request_lines,
                      [:pointer, :pointer, :pointer], :pointer
      attach_function :gpiod_line_request_release,  [:pointer], :void

      # Returns LINE_VALUE_ACTIVE / LINE_VALUE_INACTIVE / LINE_VALUE_ERROR
      attach_function :gpiod_line_request_get_value,
                      [:pointer, :uint], :int
      # Returns 0 on success, -1 on error
      attach_function :gpiod_line_request_set_value,
                      [:pointer, :uint, :int], :int

      # -----------------------------------------------------------------------
      # Edge event waiting / reading
      # timeout_ns: -1 = block forever, 0 = non-blocking, >0 = wait N ns
      # Returns: 1 (event ready), 0 (timeout), -1 (error)
      # -----------------------------------------------------------------------
      attach_function :gpiod_line_request_wait_edge_events,
                      [:pointer, :int64], :int
      # Returns number of events read, or -1 on error
      attach_function :gpiod_line_request_read_edge_events,
                      [:pointer, :pointer], :int

      # -----------------------------------------------------------------------
      # Edge event buffer — gpiod_edge_event_buffer_*
      # -----------------------------------------------------------------------
      attach_function :gpiod_edge_event_buffer_new,        [:size_t],          :pointer
      attach_function :gpiod_edge_event_buffer_free,       [:pointer],         :void
      attach_function :gpiod_edge_event_buffer_num_events, [:pointer],         :size_t
      # index is unsigned long
      attach_function :gpiod_edge_event_buffer_get_event,  [:pointer, :ulong], :pointer

      # -----------------------------------------------------------------------
      # Edge event — gpiod_edge_event_*
      # -----------------------------------------------------------------------
      # Returns EDGE_EVENT_RISING_EDGE or EDGE_EVENT_FALLING_EDGE
      attach_function :gpiod_edge_event_get_event_type,    [:pointer], :int
      attach_function :gpiod_edge_event_get_line_offset,   [:pointer], :uint
      attach_function :gpiod_edge_event_get_timestamp_ns,  [:pointer], :uint64
    end
  end
end
