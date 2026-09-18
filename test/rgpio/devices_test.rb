require_relative "../test_helper"
require "rgpio"

# Hardware-free tests for the high-level device API. Every device accepts a
# `chip:` so several devices can share one handle; these tests pass a fake chip
# instead, which keeps libgpiod (and any GPIO hardware) out of the picture.
class DevicesTest < Minitest::Test
  # Records what request_lines was asked for and hands back a FakeRequest.
  class FakeChip
    attr_reader :requests, :closed

    def initialize
      @requests = []
      @closed = false
    end

    def request_lines(**options)
      @requests << options
      FakeRequest.new(options.fetch(:offsets))
    end

    def close
      @closed = true
    end
  end

  class FakeRequest
    attr_reader :writes, :released

    # Edge events handed to the watcher thread, one batch per read.
    attr_accessor :event_batches

    def initialize(offsets)
      @offsets = offsets
      @writes = []
      @values = {}
      @released = false
      @event_batches = []
    end

    def set_value(offset, value)
      @writes << [offset, value]
      @values[offset] = value
    end

    def get_value(offset)
      @values.fetch(offset, :inactive)
    end

    def read_edge_events(**)
      batch = @event_batches.shift
      sleep 0.001
      batch || []
    end

    def release
      @released = true
    end
  end

  def setup
    @chip = FakeChip.new
  end

  # --- OutputDevice / LED --------------------------------------------- #

  def test_led_requests_an_output_line
    Rgpio::LED.new(4, chip: @chip)
    options = @chip.requests.first

    assert_equal [4], options[:offsets]
    assert_equal :output, options[:direction]
    assert_equal :inactive, options[:initial_value]
  end

  def test_led_on_off_and_toggle_drive_the_line
    led = Rgpio::LED.new(4, chip: @chip)
    led.on
    led.off
    led.toggle

    assert_equal [[4, :active], [4, :inactive], [4, :active]], request_for(led).writes
    assert_predicate led, :on?
  end

  def test_initial_value_is_passed_through
    Rgpio::LED.new(4, initial_value: true, chip: @chip)

    assert_equal :active, @chip.requests.first[:initial_value]
  end

  # --- chip ownership -------------------------------------------------- #

  def test_close_releases_the_line_but_not_a_borrowed_chip
    led = Rgpio::LED.new(4, chip: @chip)
    request = request_for(led)
    led.close

    assert_predicate request, :released
    refute @chip.closed, "a chip passed in by the caller must not be closed by the device"
    assert_predicate led, :closed?
  end

  def test_close_is_idempotent
    led = Rgpio::LED.new(4, chip: @chip)
    led.close
    led.close

    assert_predicate led, :closed?
  end

  # --- InputDevice bias mapping ---------------------------------------- #

  def test_pull_down_is_the_default_bias
    Rgpio::InputDevice.new(4, chip: @chip)

    assert_equal :pull_down, @chip.requests.first[:bias]
    assert_equal :input, @chip.requests.first[:direction]
    assert_equal :both, @chip.requests.first[:edge]
  end

  def test_pull_up_true_selects_pull_up_bias
    Rgpio::InputDevice.new(4, pull_up: true, chip: @chip)

    assert_equal :pull_up, @chip.requests.first[:bias]
  end

  def test_pull_up_nil_disables_bias
    Rgpio::InputDevice.new(4, pull_up: nil, chip: @chip)

    assert_equal :disabled, @chip.requests.first[:bias]
  end

  def test_invalid_pull_up_is_rejected
    assert_raises(ArgumentError) { Rgpio::InputDevice.new(4, pull_up: :up, chip: @chip) }
  end

  def test_button_debounces_by_default_and_motion_sensor_does_not
    Rgpio::Button.new(4, chip: @chip)
    Rgpio::MotionSensor.new(5, chip: @chip)

    assert_equal Rgpio::Button::DEBOUNCE_US, @chip.requests[0][:debounce_us]
    assert_equal 0, @chip.requests[1][:debounce_us]
  end

  # --- edge callbacks --------------------------------------------------- #

  def test_button_dispatches_pressed_and_released
    button = Rgpio::Button.new(4, chip: @chip)
    request_for(button).event_batches = [
      [{ type: :rising, offset: 4, timestamp_ns: 1 }],
      [{ type: :falling, offset: 4, timestamp_ns: 2 }],
    ]

    seen = Queue.new
    button.when_pressed  { seen << :pressed }
    button.when_released { seen << :released }

    assert_equal :pressed, seen.pop
    assert_equal :released, seen.pop
    button.close
  end

  def test_motion_sensor_dispatches_when_motion
    sensor = Rgpio::MotionSensor.new(4, chip: @chip)
    request_for(sensor).event_batches = [[{ type: :rising, offset: 4, timestamp_ns: 1 }]]

    seen = Queue.new
    sensor.when_motion { seen << :motion }

    assert_equal :motion, seen.pop
    sensor.close
  end

  def test_a_raising_callback_does_not_stop_the_watcher
    button = Rgpio::Button.new(4, chip: @chip)
    request_for(button).event_batches = [
      [{ type: :rising, offset: 4, timestamp_ns: 1 }],
      [{ type: :rising, offset: 4, timestamp_ns: 2 }],
    ]

    seen = Queue.new
    calls = 0
    _out, err = capture_io do
      button.when_pressed do
        calls += 1
        seen << calls
        raise "boom" if calls == 1
      end

      assert_equal 1, seen.pop
      assert_equal 2, seen.pop
      button.close
    end

    assert_match(/callback for GPIO4 raised RuntimeError: boom/, err)
  end

  def test_callbacks_require_a_block
    button = Rgpio::Button.new(4, chip: @chip)

    assert_raises(ArgumentError) { button.when_pressed }
  end

  def test_close_stops_the_watcher_thread_before_releasing
    button = Rgpio::Button.new(4, chip: @chip)
    button.when_pressed { nil }
    button.close

    assert_predicate request_for(button), :released
  end

  # --- Motor ------------------------------------------------------------ #

  def test_motor_requests_two_output_lines_on_the_same_chip
    Rgpio::Motor.new(forward: 2, backward: 14, chip: @chip)

    assert_equal([[2], [14]], @chip.requests.map { |o| o[:offsets] })
    assert_equal(%i[output output], @chip.requests.map { |o| o[:direction] })
  end

  def test_motor_drops_the_opposite_direction_before_driving
    motor = Rgpio::Motor.new(forward: 2, backward: 14, chip: @chip)
    forward = motor.instance_variable_get(:@forward)
    backward = motor.instance_variable_get(:@backward)
    motor.forward
    motor.backward

    assert_equal [[2, :active], [2, :inactive]], request_for(forward).writes
    assert_equal [[14, :inactive], [14, :active]], request_for(backward).writes
  end

  def test_motor_stops_and_releases_both_lines_on_close
    motor = Rgpio::Motor.new(forward: 2, backward: 14, chip: @chip)
    forward = motor.instance_variable_get(:@forward)
    backward = motor.instance_variable_get(:@backward)
    motor.forward
    motor.close

    assert_predicate request_for(forward), :released
    assert_predicate request_for(backward), :released
    assert_equal [2, :inactive], request_for(forward).writes.last
  end

  # --- Rgpio.pause ------------------------------------------------------- #

  def test_pause_returns_when_interrupted
    main = Thread.current
    Thread.new do
      sleep 0.05
      main.raise Interrupt
    end

    assert_nil Rgpio.pause
  end

  private

  def request_for(device)
    device.instance_variable_get(:@request)
  end
end
