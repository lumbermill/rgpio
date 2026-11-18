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
    # Values go through ioctls on the request's file descriptor rather than
    # through libgpiod's value functions. Each fiddle call costs ~2 us on a
    # Pi 5 but ~75-90 us on an ARMv6 Pi Zero, where libgpiod's set_value came
    # to 158 us against 19 us for the same ioctl issued with IO#ioctl — and
    # SoftwarePWM makes three such calls per cycle. libgpiod's value functions
    # are themselves a thin wrapper over these two ioctls.
    #
    # From <linux/gpio.h>: _IOWR(0xB4, 0x0E / 0x0F, struct gpio_v2_line_values),
    # where the struct is { __u64 bits; __u64 mask; } — 16 bytes on 32- and
    # 64-bit alike. Bit i stands for the i-th line *of the request* (not the
    # offset), and the kernel applies active_low, so bits are logical values.
    IOC_READ_WRITE = 3
    IOC_MAGIC = 0xB4
    LINE_VALUES_SIZE = 16

    # @return [Integer] an encoded ioctl request
    def self.ioctl_number(direction, request, size)
      (direction << 30) | (size << 16) | (IOC_MAGIC << 8) | request
    end

    GET_VALUES_IOCTL = ioctl_number(IOC_READ_WRITE, 0x0E, LINE_VALUES_SIZE)
    SET_VALUES_IOCTL = ioctl_number(IOC_READ_WRITE, 0x0F, LINE_VALUES_SIZE)

    # Pack a struct gpio_v2_line_values. One byte longer than the struct:
    # IO#ioctl wants room for a sentinel after the data and would otherwise
    # reallocate the string on every call.
    # @return [String] a mutable binary buffer
    def self.pack_line_values(bits, mask)
      [bits, mask, 0].pack("QQC")
    end

    # @return [Integer] the bits field of a buffer from pack_line_values
    def self.unpack_line_bits(buffer)
      buffer.unpack1("Q")
    end

    # @param request_ptr [Fiddle::Pointer] raw gpiod_line_request*
    # @param offsets     [Array<Integer>] offsets included in this request
    def initialize(request_ptr, offsets)
      @request_ptr = request_ptr
      @offsets = offsets.freeze
      kernel_order = request_ptr.null? ? offsets : requested_offsets
      @index = kernel_order.each_with_index.to_h.freeze
      # Prebuilt per line, so a single-line write allocates nothing: on 32-bit
      # Ruby even a Float is a heap object, and garbage in SoftwarePWM's loop
      # turns into GC pauses of several milliseconds on a Pi Zero.
      @set_active = @index.values.map { |i| self.class.pack_line_values(1 << i, 1 << i) }.freeze
      @set_inactive = @index.values.map { |i| self.class.pack_line_values(0, 1 << i) }.freeze
      @get_mask = @index.values.map { |i| self.class.pack_line_values(0, 1 << i) }.freeze
      @io = request_ptr.null? ? nil : IO.for_fd(Native.gpiod_line_request_get_fd(request_ptr), autoclose: false)
    end

    attr_reader :offsets

    # Read the current value of a single line.
    #
    # @param offset [Integer] GPIO line offset (must be in #offsets)
    # @return [:active, :inactive]
    # @raise [SystemCallError] on error
    def get_value(offset)
      assert_active!
      i = index_of(offset)
      buffer = @get_mask[i].dup
      @io.ioctl(GET_VALUES_IOCTL, buffer)
      self.class.unpack_line_bits(buffer)[i] == 1 ? :active : :inactive
    end

    # Set the output value of a single line.
    #
    # @param offset [Integer] GPIO line offset
    # @param value  [:active, :inactive, 1, 0] desired output level
    # @raise [SystemCallError] on error
    def set_value(offset, value)
      assert_active!
      i = index_of(offset)
      buffer = normalize_value(value) == Native::LINE_VALUE_ACTIVE ? @set_active[i] : @set_inactive[i]
      @io.ioctl(SET_VALUES_IOCTL, buffer)
      nil
    end

    # Read several lines atomically in a single ioctl.
    #
    # @param offsets [Array<Integer>] offsets to read; defaults to every offset
    #                in this request. Must be a subset of #offsets.
    # @return [Hash{Integer=>Symbol}] offset => :active / :inactive, in the
    #                order given
    # @raise [SystemCallError] on error
    def get_values(offsets = @offsets)
      assert_active!
      offs = Array(offsets)
      return {} if offs.empty?

      mask = offs.reduce(0) { |m, offset| m | (1 << index_of(offset)) }
      buffer = self.class.pack_line_values(0, mask)
      @io.ioctl(GET_VALUES_IOCTL, buffer)
      bits = self.class.unpack_line_bits(buffer)
      offs.to_h { |offset| [offset, bits[index_of(offset)] == 1 ? :active : :inactive] }
    end

    # Set several output lines atomically in a single ioctl.
    #
    # @param values [Hash{Integer=>Object}] offset => desired level
    #               (:active/:inactive/1/0/true/false). Offsets must be a subset
    #               of #offsets.
    # @raise [ArgumentError] when values is not a Hash
    # @raise [SystemCallError] on error
    def set_values(values)
      assert_active!
      raise ArgumentError, "set_values expects a Hash of offset => value, got #{values.class}" unless values.is_a?(Hash)
      return if values.empty?

      bits = mask = 0
      values.each do |offset, value|
        bit = 1 << index_of(offset)
        mask |= bit
        bits |= bit if normalize_value(value) == Native::LINE_VALUE_ACTIVE
      end
      @io.ioctl(SET_VALUES_IOCTL, self.class.pack_line_values(bits, mask))
      nil
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
            type: type_int == Native::EDGE_EVENT_RISING_EDGE ? :rising : :falling,
            offset: Native.gpiod_edge_event_get_line_offset(ev),
            timestamp_ns: Native.gpiod_edge_event_get_timestamp_ns(ev),
          }
        end
      ensure
        Native.gpiod_edge_event_buffer_free(buf) if buf && !buf.null?
      end
    end

    # Release the kernel line request. Safe to call multiple times.
    def release
      return unless @request_ptr && !@request_ptr.null?

      # Marks the IO closed without closing the fd (autoclose: false);
      # libgpiod closes the fd itself just below.
      @io&.close
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

    # @return [Integer] the line's bit position in this request
    def index_of(offset)
      @index.fetch(offset) do
        raise Errno::EINVAL, "GPIO#{offset} is not in this request (offsets: #{@offsets.join(", ")})"
      end
    end

    # Offsets as libgpiod handed them to the kernel, i.e. in bit order.
    def requested_offsets
      count = Native.gpiod_line_request_get_num_requested_lines(@request_ptr)
      buffer = Native.uint32_buffer(Array.new(count, 0))
      Native.gpiod_line_request_get_requested_offsets(@request_ptr, buffer, count)
      buffer[0, count * 4].unpack("L*")
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
