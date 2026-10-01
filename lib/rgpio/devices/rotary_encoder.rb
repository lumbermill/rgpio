module Rgpio
  # A quadrature rotary encoder such as the KY-040 module.
  #
  #   encoder = Rgpio::RotaryEncoder.new(a: 17, b: 18, max_steps: 16)
  #   encoder.when_rotated_clockwise         { puts "CW  #{encoder.steps}" }
  #   encoder.when_rotated_counter_clockwise { puts "CCW #{encoder.steps}" }
  #   Rgpio.pause
  #
  # Both phases are claimed in one request so a single watcher thread reads
  # their edges from one kernel queue, in timestamp order. Unlike Button the
  # watcher starts at once: steps are counted whether or not a callback is set.
  #
  # Each edge is decoded through the Gray-code transition table into +1 or -1,
  # and a step is counted only when the phases come back to rest four
  # transitions on. Contact bounce moves the phases back and forth, so its
  # transitions cancel out and never reach a full detent. Rest is both high
  # with pull_up: true or nil (the KY-040 has its own pull-ups), both low with
  # pull_up: false. Clockwise is A changing before B; if a knob counts
  # backwards, swap a: and b:.
  #
  # The push switch on the shaft is a separate contact: use Rgpio::Button.
  class RotaryEncoder < Device
    # How long a single edge wait blocks before the watcher rechecks whether it
    # has been asked to stop.
    WATCH_TIMEOUT = 0.2

    # Direction of each move between two phase states, indexed by
    # (previous << 2) | current with a state of (A << 1) | B. Clockwise runs
    # 00 -> 10 -> 11 -> 01 -> 00; no change and two-bit jumps are 0.
    TRANSITIONS = [
      0, -1, 1, 0,
      1, 0, 0, -1,
      -1, 0, 0, 1,
      0, 1, -1, 0,
    ].freeze

    # Transitions per detent.
    TRANSITIONS_PER_STEP = 4

    # @param a           [Integer] GPIO line of phase A (CLK on a KY-040)
    # @param b           [Integer] GPIO line of phase B (DT on a KY-040)
    # @param max_steps   [Integer] bound of #steps in either direction; 0 for none
    # @param wrap        [Boolean] past a bound, continue from the other end
    #                    instead of stopping there
    # @param pull_up     [Boolean, nil] internal bias, as for InputDevice
    # @param debounce_us [Integer] kernel debounce window in microseconds
    # @param chip        [Chip, nil] chip to share, or nil to open one
    # @param consumer    [String] name shown in the kernel's request list
    def initialize(a:, b:, max_steps: 16, wrap: false, pull_up: true, debounce_us: 0, chip: nil, consumer: "rgpio")
      unless max_steps.is_a?(Integer) && max_steps >= 0
        raise ArgumentError, "max_steps must be a non-negative Integer, got #{max_steps.inspect}"
      end

      bias = bias_for(pull_up)
      super(chip: chip)
      @a = a
      @b = b
      @max_steps = max_steps
      @wrap = wrap
      @rest = pull_up == false ? 0b00 : 0b11
      @steps = 0
      @partial = 0
      @callbacks = {}
      @lock = Mutex.new
      @request = @chip.request_lines(
        offsets: [a, b],
        direction: :input,
        edge: :both,
        bias: bias,
        debounce_us: debounce_us,
        consumer: consumer
      )
      @state = (level(@a) << 1) | level(@b)
      start_watching
    end

    # @return [Integer] GPIO lines of phase A and phase B
    attr_reader :a, :b

    # @return [Integer] the bound of #steps, or 0 when unbounded
    attr_reader :max_steps

    # @return [Integer] detents turned since start, clockwise positive
    def steps
      @lock.synchronize { @steps }
    end

    # Set the count, bounded (or wrapped) like rotation is.
    def steps=(value)
      raise ArgumentError, "steps must be an Integer, got #{value.inspect}" unless value.is_a?(Integer)

      @lock.synchronize { @steps = bound(value) }
    end

    # @return [Float] #steps / #max_steps in -1.0..1.0, or 0.0 when unbounded
    def value
      return 0.0 if @max_steps.zero?

      steps.fdiv(@max_steps)
    end

    def wrap?
      @wrap
    end

    # Callbacks fire once per detent, also at a bound where #steps stays put.

    def when_rotated(&)
      on(:rotated, &)
    end

    def when_rotated_clockwise(&)
      on(:clockwise, &)
    end

    def when_rotated_counter_clockwise(&)
      on(:counter_clockwise, &)
    end

    private

    def bias_for(pull_up)
      case pull_up
      when true then :pull_up
      when false then :pull_down
      when nil then :disabled
      else raise ArgumentError, "pull_up must be true, false or nil, got #{pull_up.inspect}"
      end
    end

    def level(offset)
      @request.get_value(offset) == :active ? 1 : 0
    end

    def on(kind, &block)
      raise ArgumentError, "a callback block is required" unless block

      @callbacks[kind] = block
      self
    end

    def bound(value)
      return value if @max_steps.zero?
      return value.clamp(-@max_steps, @max_steps) unless @wrap

      span = (2 * @max_steps) + 1
      ((value + @max_steps) % span) - @max_steps
    end

    def start_watching
      @watching = true
      @watcher = Thread.new { watch_loop }
    end

    def watch_loop
      @request.read_edge_events(timeout: WATCH_TIMEOUT).each { |event| handle(event) } while @watching
    rescue StandardError => e
      warn "rgpio: edge watcher for GPIO#{@a}/GPIO#{@b} stopped: #{e.class}: #{e.message}"
    end

    # Fold one edge into the phase state, and count a step once the phases are
    # back at rest. Each edge changes one bit, so the net at rest is 0 (a half
    # turn and back, or bounce) or a full detent either way. A repeated edge
    # for a line already at that level changes nothing and reads as 0.
    def handle(event)
      bit = event[:offset] == @a ? 0b10 : 0b01
      current = event[:type] == :rising ? @state | bit : @state & ~bit
      @partial += TRANSITIONS[(@state << 2) | current]
      @state = current
      return unless current == @rest

      direction = @partial.abs >= TRANSITIONS_PER_STEP ? @partial <=> 0 : 0
      @partial = 0
      rotate(direction) unless direction.zero?
    end

    def rotate(direction)
      @lock.synchronize { @steps = bound(@steps + direction) }
      dispatch(direction.positive? ? :clockwise : :counter_clockwise)
      dispatch(:rotated)
    end

    # A raising callback must not take the watcher down with it.
    def dispatch(kind)
      callback = @callbacks[kind]
      return unless callback

      callback.call
    rescue StandardError => e
      warn "rgpio: #{self.class} callback for GPIO#{@a}/GPIO#{@b} raised #{e.class}: #{e.message}"
    end

    # Stop the watcher before releasing the request: a wait in progress holds a
    # pointer into the request that libgpiod would free underneath it.
    def release_resources
      @watching = false
      @watcher&.join
      @watcher = nil
      @request.release
    end
  end
end
