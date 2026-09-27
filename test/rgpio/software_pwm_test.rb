require_relative "../test_helper"
require "rgpio"

# Hardware-free tests for Rgpio::SoftwarePWM. The waveform itself is timed by
# the OS, so what is asserted here is the shape (which levels get written, in
# what order) and the bookkeeping — the timing accuracy is a hardware question,
# measured with examples/pwm_jitter.rb.
class SoftwarePWMTest < Minitest::Test
  # Records every level written. The generating thread writes while the test
  # reads, so the log is guarded.
  class FakeChip
    attr_reader :closed

    def initialize
      @closed = false
      @requests = []
    end

    def request_lines(**options)
      request = FakeRequest.new(options)
      @requests << request
      request
    end

    def last_request
      @requests.last
    end

    def close
      @closed = true
    end
  end

  class FakeRequest
    attr_reader :options, :released

    def initialize(options)
      @options = options
      @writes = []
      @mutex = Mutex.new
      @released = false
    end

    def set_value(offset, value)
      @mutex.synchronize { @writes << [offset, value] }
    end

    def writes
      @mutex.synchronize { @writes.dup }
    end

    def levels
      writes.map(&:last)
    end

    def release
      @released = true
    end
  end

  def setup
    @chip = FakeChip.new
  end

  def pwm(**)
    Rgpio::SoftwarePWM.new(18, chip: @chip, **)
  end

  # Run a channel briefly and hand back the levels it wrote.
  def run_briefly(pwm, seconds: 0.08)
    pwm.enable
    sleep seconds
    pwm.disable
    @chip.last_request.levels
  end

  def test_claims_the_line_as_an_output_that_starts_inactive
    pwm(frequency: 100)

    assert_equal [18], @chip.last_request.options[:offsets]
    assert_equal :output, @chip.last_request.options[:direction]
    assert_equal :inactive, @chip.last_request.options[:initial_value]
  end

  def test_rejects_a_frequency_outside_the_supported_range
    assert_raises(ArgumentError) { pwm(frequency: 0) }
    assert_raises(ArgumentError) { pwm(frequency: 20_000) }
    assert_raises(ArgumentError) { pwm(frequency: "fast") }
  end

  def test_rejects_a_duty_cycle_outside_0_to_1
    assert_raises(ArgumentError) { pwm(duty_cycle: -0.1) }
    assert_raises(ArgumentError) { pwm(duty_cycle: 1.5) }
  end

  def test_rejects_a_negative_spin_window
    assert_raises(ArgumentError) { pwm(spin_us: -1) }
  end

  def test_setters_update_the_readers
    channel = pwm(frequency: 100, duty_cycle: 0.1)
    channel.frequency = 50
    channel.duty_cycle = 0.25

    assert_in_delta 50, channel.frequency
    assert_in_delta 0.25, channel.duty_cycle
    assert_in_delta 0.25, channel.duty_ratio
    assert_equal Rgpio::SoftwarePWM::DEFAULT_SPIN_US, channel.spin_us
  end

  # 1500 us of a 20 ms frame is the centre position of a servo.
  def test_pulse_width_converts_to_and_from_duty_cycle
    channel = pwm(frequency: 50)
    channel.pulse_width_us = 1500

    assert_in_delta 0.075, channel.duty_cycle
    assert_in_delta 1500, channel.pulse_width_us

    channel.frequency = 100 # same duty, half the frame
    assert_in_delta 750, channel.pulse_width_us
  end

  def test_rejects_a_negative_pulse_width
    assert_raises(ArgumentError) { pwm(frequency: 50).pulse_width_us = -1 }
  end

  def test_toggles_the_line_while_running
    levels = run_briefly(pwm(frequency: 500, duty_cycle: 0.5))

    assert_includes levels, :active
    assert_includes levels, :inactive
    # Every high must be followed by a low: no two highs in a row.
    assert(levels.each_cons(2).none? { |a, b| a == :active && b == :active })
  end

  def test_a_duty_cycle_of_zero_never_raises_the_line
    levels = run_briefly(pwm(frequency: 500, duty_cycle: 0.0))

    refute_includes levels, :active
  end

  def test_a_duty_cycle_of_one_never_lowers_the_line_until_it_stops
    channel = pwm(frequency: 500, duty_cycle: 1.0)
    channel.enable
    sleep 0.08
    running_levels = @chip.last_request.levels
    channel.disable

    refute_includes running_levels, :inactive
    assert_includes running_levels, :active
  end

  def test_disable_stops_the_thread_and_leaves_the_line_inactive
    channel = pwm(frequency: 500, duty_cycle: 0.5)
    channel.enable

    assert_predicate channel, :enabled?
    sleep 0.05
    channel.disable

    refute_predicate channel, :enabled?
    assert_equal :inactive, @chip.last_request.levels.last

    before = @chip.last_request.writes.size
    sleep 0.05

    assert_equal before, @chip.last_request.writes.size, "the generating thread must have stopped"
  end

  def test_enable_is_idempotent
    channel = pwm(frequency: 500, duty_cycle: 0.5)
    channel.enable
    channel.enable

    assert_predicate channel, :enabled?
    channel.close
  end

  def test_close_releases_the_line_but_not_a_shared_chip
    channel = pwm(frequency: 500, duty_cycle: 0.5)
    channel.enable
    channel.close

    assert_predicate channel, :closed?
    assert @chip.last_request.released
    refute @chip.closed, "a shared chip must outlive the channel"
    refute_predicate channel, :enabled?
  end

  def test_close_is_idempotent_and_enable_afterwards_raises
    channel = pwm(frequency: 500)
    channel.close
    channel.close

    assert_raises(Rgpio::Error) { channel.enable }
  end

  def test_inspect_reports_the_channel_state
    assert_match(/gpio=18 frequency=100Hz duty_cycle=0\.250/, pwm(frequency: 100, duty_cycle: 0.25).inspect)
  end
end
