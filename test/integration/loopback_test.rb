require_relative "../test_helper"
require "rgpio"

# Hardware tests over a GPIO loopback: two header pins joined by a jumper wire,
# one driven as an output and the other read as an input.
#
# Set RGPIO_LOOPBACK to the wired pair, output first (BCM numbering):
#
#   RGPIO_LOOPBACK=17:27 rake integration
#
# Without it every test is skipped, so the suite is safe to run anywhere.
class LoopbackTest < Minitest::Test
  # How long to wait for an edge event or callback that should arrive.
  EVENT_TIMEOUT = 1.0

  # How long to wait to be sure an event does NOT arrive.
  QUIET_TIMEOUT = 0.1

  # Spacing between edges in the burst test (see test_several_toggles_...).
  TOGGLE_GAP = 0.001

  def self.loopback_pair
    spec = ENV.fetch("RGPIO_LOOPBACK", "")
    match = spec.match(/\A(\d+):(\d+)\z/)
    match && [match[1].to_i, match[2].to_i]
  end

  def setup
    pair = self.class.loopback_pair
    skip "set RGPIO_LOOPBACK=<out>:<in> (e.g. 17:27) to run loopback tests" unless pair
    skip "libgpiod is not available" unless Rgpio.available?

    @out, @in = pair
    @chip = Rgpio::Chip.new
    @requests = []
  end

  def teardown
    @requests&.each(&:release)
    @chip&.close
  end

  # --- Level: output drives the input ---------------------------------- #

  def test_input_follows_output_against_pull_down
    out = request_output
    inp = request_input(bias: :pull_down)

    out.set_value(@out, :active)
    assert_equal :active, inp.get_value(@in)

    out.set_value(@out, :inactive)
    assert_equal :inactive, inp.get_value(@in)
  end

  # Against a pull-up, a low reading can only come from the wire.
  def test_input_follows_output_against_pull_up
    out = request_output
    inp = request_input(bias: :pull_up)

    out.set_value(@out, :inactive)
    assert_equal :inactive, inp.get_value(@in)

    out.set_value(@out, :active)
    assert_equal :active, inp.get_value(@in)
  end

  def test_initial_value_active_is_driven_at_request_time
    request_output(initial_value: :active)
    inp = request_input(bias: :pull_down)

    assert_equal :active, inp.get_value(@in)
  end

  def test_active_low_input_inverts_reading
    out = request_output
    inp = request_input(bias: :pull_down, active_low: true)

    out.set_value(@out, :active)
    assert_equal :inactive, inp.get_value(@in)

    out.set_value(@out, :inactive)
    assert_equal :active, inp.get_value(@in)
  end

  # --- Batch I/O -------------------------------------------------------- #

  def test_set_values_and_get_values
    out = request_output
    inp = request_input(bias: :pull_down)

    out.set_values(@out => :active)
    assert_equal({ @in => :active }, inp.get_values)

    out.set_values(@out => 0)
    assert_equal({ @in => :inactive }, inp.get_values)
  end

  # --- Edge events ------------------------------------------------------ #

  def test_both_edges_are_reported_in_order
    out = request_output
    inp = request_input(bias: :pull_down, edge: :both)
    drain(inp)

    out.set_value(@out, :active)
    rising = next_event(inp)
    out.set_value(@out, :inactive)
    falling = next_event(inp)

    assert_equal :rising, rising[:type]
    assert_equal @in, rising[:offset]
    assert_equal :falling, falling[:type]
    assert_equal @in, falling[:offset]
    assert_operator falling[:timestamp_ns], :>, rising[:timestamp_ns]
  end

  def test_rising_only_ignores_falling_edge
    out = request_output(initial_value: :active)
    inp = request_input(bias: :pull_down, edge: :rising)
    drain(inp)

    out.set_value(@out, :inactive)
    assert_empty inp.read_edge_events(timeout: QUIET_TIMEOUT)

    out.set_value(@out, :active)
    assert_equal :rising, next_event(inp)[:type]
  end

  def test_falling_only_ignores_rising_edge
    out = request_output
    inp = request_input(bias: :pull_down, edge: :falling)
    drain(inp)

    out.set_value(@out, :active)
    assert_empty inp.read_edge_events(timeout: QUIET_TIMEOUT)

    out.set_value(@out, :inactive)
    assert_equal :falling, next_event(inp)[:type]
  end

  def test_wait_edge_events_times_out_without_change
    request_output
    inp = request_input(bias: :pull_down, edge: :both)
    drain(inp)

    refute inp.wait_edge_events(timeout: QUIET_TIMEOUT)
  end

  # Edges must be spaced out a little. Back-to-back set_value calls (a few µs
  # apart) beat the kernel's edge interrupt: on a Pi 5 (kernel 6.18) about half
  # such runs lose edges or report the wrong type, because with edge: :both
  # the kernel reads the line level to decide the type. 0.1 ms was already
  # reliable (50/50); 1 ms leaves margin.
  def test_several_toggles_are_all_buffered
    out = request_output
    inp = request_input(bias: :pull_down, edge: :both)
    drain(inp)

    3.times do
      out.set_value(@out, :active)
      sleep TOGGLE_GAP
      out.set_value(@out, :inactive)
      sleep TOGGLE_GAP
    end
    sleep QUIET_TIMEOUT

    types = inp.read_edge_events(timeout: 0).map { |e| e[:type] }
    assert_equal %i[rising falling] * 3, types
  end

  # --- Ownership: request, conflict, release ---------------------------- #

  def test_line_info_reports_consumer_while_held
    request_input(bias: :pull_down, consumer: "rgpio-loopback")

    info = @chip.line_info(@in)
    assert info[:used]
    assert_equal "rgpio-loopback", info[:consumer]
  end

  def test_second_request_names_the_holder
    request_input(bias: :pull_down, consumer: "rgpio-loopback")

    error = assert_raises(SystemCallError) do
      @chip.request_lines(offsets: [@in], direction: :input)
    end
    assert_includes error.message, "GPIO#{@in} is already in use by \"rgpio-loopback\""
  end

  def test_release_frees_the_line
    inp = request_input(bias: :pull_down)
    inp.release

    refute @chip.line_info(@in)[:used]
    request_input(bias: :pull_down) # would raise if still held
  end

  # --- Device API: LED drives Button ------------------------------------ #

  def test_led_drives_button_callbacks
    led = Rgpio::LED.new(@out, chip: @chip)
    button = Rgpio::Button.new(@in, chip: @chip)
    events = Thread::Queue.new
    button.when_pressed { events << :pressed }
    button.when_released { events << :released }

    led.on
    assert_equal :pressed, events.pop(timeout: EVENT_TIMEOUT)
    assert button.pressed?

    led.off
    assert_equal :released, events.pop(timeout: EVENT_TIMEOUT)
    refute button.pressed?
  ensure
    button&.close
    led&.close
  end

  private

  def request_output(initial_value: :inactive)
    track @chip.request_lines(offsets: [@out], direction: :output,
                              initial_value: initial_value, consumer: "rgpio-loopback")
  end

  def request_input(bias:, edge: :none, active_low: false, consumer: "rgpio-loopback")
    track @chip.request_lines(offsets: [@in], direction: :input, edge: edge,
                              bias: bias, active_low: active_low, consumer: consumer)
  end

  def track(request)
    @requests << request
    request
  end

  # Discard any events left over from setting up the lines.
  def drain(request)
    request.read_edge_events(timeout: QUIET_TIMEOUT)
  end

  def next_event(request)
    events = request.read_edge_events(timeout: EVENT_TIMEOUT, capacity: 1)
    refute_empty events, "expected an edge event within #{EVENT_TIMEOUT}s"
    events.first
  end
end
