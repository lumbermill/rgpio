# frozen_string_literal: true

module Rgpio
  # A single GPIO line read as an input, with optional edge callbacks.
  #
  # Callbacks run on a background thread that waits on kernel edge events, so
  # the main thread is free (see {Rgpio.pause}). The thread is started by the
  # first callback registration and stopped by #close.
  class InputDevice < Device
    # How long a single edge wait blocks before the watcher rechecks whether it
    # has been asked to stop.
    WATCH_TIMEOUT = 0.2

    # @param gpio        [Integer] GPIO line offset (BCM numbering)
    # @param pull_up     [Boolean, nil] internal bias: true = pull-up (wire the
    #                    switch to GND), false = pull-down (wire it to 3.3 V),
    #                    nil = no bias (external resistor)
    # @param active_low  [Boolean] when true, a low line reads as active
    # @param debounce_us [Integer] kernel debounce window in microseconds
    # @param chip        [Chip, nil] chip to share, or nil to open one
    # @param consumer    [String] name shown in the kernel's request list
    def initialize(gpio, pull_up: false, active_low: false, debounce_us: 0, chip: nil, consumer: "rgpio")
      super(chip: chip)
      @gpio = gpio
      @callbacks = {}
      @request = @chip.request_lines(
        offsets: [gpio],
        direction: :input,
        edge: :both,
        bias: bias_for(pull_up),
        active_low: active_low,
        debounce_us: debounce_us,
        consumer: consumer
      )
    end

    # @return [Integer] the GPIO line offset this device reads
    attr_reader :gpio

    # @return [Boolean] true when the line is at its active level
    def value
      @request.get_value(@gpio) == :active
    end

    alias active? value

    private

    def bias_for(pull_up)
      case pull_up
      when true then :pull_up
      when false then :pull_down
      when nil then :disabled
      else raise ArgumentError, "pull_up must be true, false or nil, got #{pull_up.inspect}"
      end
    end

    # Register +block+ for the transition to :active or :inactive, and make sure
    # the watcher thread is running.
    def on_edge(state, &block)
      raise ArgumentError, "a callback block is required" unless block

      @callbacks[state] = block
      start_watching
      self
    end

    def start_watching
      return if @watcher

      @watching = true
      @watcher = Thread.new { watch_loop }
    end

    def watch_loop
      while @watching
        @request.read_edge_events(timeout: WATCH_TIMEOUT).each do |event|
          dispatch(event[:type] == :rising ? :active : :inactive)
        end
      end
    rescue StandardError => e
      warn "rgpio: edge watcher for GPIO#{@gpio} stopped: #{e.class}: #{e.message}"
    end

    # A raising callback must not take the watcher down with it, or the device
    # would go quiet with no indication why.
    def dispatch(state)
      callback = @callbacks[state]
      return unless callback

      callback.call
    rescue StandardError => e
      warn "rgpio: #{self.class} callback for GPIO#{@gpio} raised #{e.class}: #{e.message}"
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

  # A push button or switch.
  #
  #   button = Rgpio::Button.new(4)
  #   button.when_pressed  { puts "Pressed" }
  #   button.when_released { puts "Released" }
  #   Rgpio.pause
  #
  # The default pull-down bias suits a switch wired between the GPIO line and
  # 3.3 V. Pass pull_up: true for a switch wired to GND instead.
  class Button < InputDevice
    # Mechanical contacts bounce for a few milliseconds; without this one press
    # fires the callback several times.
    DEBOUNCE_US = 5_000

    def initialize(gpio, pull_up: false, active_low: false, debounce_us: DEBOUNCE_US, chip: nil, consumer: "rgpio")
      super
    end

    def when_pressed(&)
      on_edge(:active, &)
    end

    def when_released(&)
      on_edge(:inactive, &)
    end

    alias pressed? value
  end

  # A PIR motion sensor. Its output is a clean digital signal, so no debounce
  # is applied.
  #
  #   sensor = Rgpio::MotionSensor.new(4)
  #   sensor.when_motion { puts "motion detected!" }
  #   Rgpio.pause
  class MotionSensor < InputDevice
    def when_motion(&)
      on_edge(:active, &)
    end

    def when_no_motion(&)
      on_edge(:inactive, &)
    end

    alias motion_detected? value
  end
end
