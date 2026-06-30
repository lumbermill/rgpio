# frozen_string_literal: true

module Rgpio
  # Holds an active kernel line request returned by Chip#request_lines.
  # Must be released when done via #release (or the block form of Chip.open).
  #
  # Example — output:
  #   request = chip.request_lines(offsets: [17], direction: :output)
  #   request.set_value(17, :active)
  #   request.release
  #
  # Example — input with edge detection (blocking):
  #   request = chip.request_lines(offsets: [27], direction: :input,
  #                                edge: :both, bias: :pull_up)
  #   loop do
  #     events = request.read_edge_events(timeout: 5.0)
  #     events.each { |e| puts "#{e[:type]} on offset #{e[:offset]}" }
  #   end
  #   request.release
  class LineRequest
    # @param request_ptr [Fiddle::Pointer] raw gpiod_line_request*
    # @param offsets     [Array<Integer>] offsets included in this request
    def initialize(request_ptr, offsets)
      @request_ptr = request_ptr
      @offsets = offsets.freeze
    end

    attr_reader :offsets

    # Read the current value of a single line.
    #
    # @param offset [Integer] GPIO line offset (must be in #offsets)
    # @return [:active, :inactive]
    # @raise [SystemCallError] on error
    def get_value(offset)
      assert_active!
      result = Native.gpiod_line_request_get_value(@request_ptr, offset)
      case result
      when Native::LINE_VALUE_ACTIVE   then :active
      when Native::LINE_VALUE_INACTIVE then :inactive
      else
        raise SystemCallError.new("gpiod_line_request_get_value(offset=#{offset})", Native.errno)
      end
    end

    # Set the output value of a single line.
    #
    # @param offset [Integer] GPIO line offset
    # @param value  [:active, :inactive, 1, 0] desired output level
    # @raise [SystemCallError] on error
    def set_value(offset, value)
      assert_active!
      v = normalize_value(value)
      ret = Native.gpiod_line_request_set_value(@request_ptr, offset, v)
      raise SystemCallError.new("gpiod_line_request_set_value(offset=#{offset})", Native.errno) if ret == -1
    end

    # Wait for edge events on any line in this request.
    #
    # @param timeout [Float, nil] seconds to wait; nil = block indefinitely;
    #                             0 = non-blocking poll
    # @return [Boolean] true if at least one event is ready
    # @raise [SystemCallError] on error
    def wait_edge_events(timeout: nil)
      assert_active!
      timeout_ns = if timeout.nil?
                     -1
                   else
                     (timeout * 1_000_000_000).to_i
                   end
      ret = Native.gpiod_line_request_wait_edge_events(@request_ptr, timeout_ns)
      raise SystemCallError.new("gpiod_line_request_wait_edge_events", Native.errno) if ret == -1
      ret == 1
    end

    # Read pending edge events into an array.
    # Typically called after #wait_edge_events returns true.
    #
    # @param timeout [Float, nil] wait up to this many seconds before reading
    # @param capacity [Integer] maximum events to read per call
    # @return [Array<Hash>] array of event hashes:
    #   { type: :rising | :falling, offset: Integer, timestamp_ns: Integer }
    def read_edge_events(timeout: nil, capacity: 16)
      assert_active!
      return [] unless wait_edge_events(timeout: timeout)

      buf = nil
      begin
        buf = Native.gpiod_edge_event_buffer_new(capacity)
        raise Error, "gpiod_edge_event_buffer_new failed" if buf.null?

        n = Native.gpiod_line_request_read_edge_events(@request_ptr, buf)
        raise SystemCallError.new("gpiod_line_request_read_edge_events", Native.errno) if n == -1

        Array.new(n) do |i|
          ev = Native.gpiod_edge_event_buffer_get_event(buf, i)
          type_int = Native.gpiod_edge_event_get_event_type(ev)
          {
            type:         type_int == Native::EDGE_EVENT_RISING_EDGE ? :rising : :falling,
            offset:       Native.gpiod_edge_event_get_line_offset(ev),
            timestamp_ns: Native.gpiod_edge_event_get_timestamp_ns(ev)
          }
        end
      ensure
        Native.gpiod_edge_event_buffer_free(buf) if buf && !buf.null?
      end
    end

    # Release the kernel line request. Safe to call multiple times.
    def release
      return unless @request_ptr && !@request_ptr.null?
      Native.gpiod_line_request_release(@request_ptr)
      @request_ptr = nil
    end

    def released?
      @request_ptr.nil?
    end

    private

    def assert_active!
      raise Error, "LineRequest has already been released" if released?
    end

    def normalize_value(value)
      case value
      when :active,   1, true  then Native::LINE_VALUE_ACTIVE
      when :inactive, 0, false then Native::LINE_VALUE_INACTIVE
      else raise ArgumentError, "Unknown line value: #{value.inspect}"
      end
    end
  end
end
