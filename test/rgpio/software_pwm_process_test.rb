require_relative "../test_helper"
require "timeout"
require "rgpio"

# Process mode of Rgpio::SoftwarePWM, without hardware. The fake request lives
# in the child after the fork, so it reports each level it is given down a pipe
# ("1" for active, "0" for inactive) for the test to read in the parent.
class SoftwarePWMProcessTest < Minitest::Test
  class PipeChip
    def initialize(out, fail_with: nil)
      @out = out
      @fail_with = fail_with
    end

    def request_lines(**)
      raise @fail_with if @fail_with

      PipeRequest.new(@out)
    end

    def close; end
  end

  class PipeRequest
    def initialize(out)
      @out = out
    end

    def set_value(_offset, value)
      @out.syswrite(value == :active ? "1" : "0")
    end

    def release
      @out.syswrite("R")
    end
  end

  def setup
    @levels_in, @levels_out = IO.pipe
    @channels = []
  end

  def teardown
    @channels.each(&:close)
    @levels_in.close
    @levels_out.close
  end

  def pwm(chip: PipeChip.new(@levels_out), **)
    channel = Rgpio::SoftwarePWM.new(18, chip: chip, process: true, **)
    @channels << channel
    channel
  end

  # Everything the child has written so far.
  def drain
    data = +""
    loop do
      chunk = @levels_in.read_nonblock(4096, exception: false)
      break unless chunk.is_a?(String)

      data << chunk
    end
    data
  end

  # Answer single_core? with `value` for the duration of the block.
  def with_single_core(value)
    original = Rgpio::SoftwarePWM.method(:single_core?)
    Rgpio::SoftwarePWM.define_singleton_method(:single_core?) { value }
    yield
  ensure
    Rgpio::SoftwarePWM.define_singleton_method(:single_core?, original)
  end

  def test_auto_picks_process_mode_only_on_a_single_core
    with_single_core(true) do
      assert_predicate Rgpio::SoftwarePWM.new(18, chip: PipeChip.new(@levels_out)).tap { @channels << _1 }, :process?
    end
    with_single_core(false) do
      fake = SoftwarePWMTest::FakeChip.new
      refute_predicate Rgpio::SoftwarePWM.new(18, chip: fake).tap { @channels << _1 }, :process?
    end
  end

  def test_rejects_an_unknown_process_option
    assert_raises(ArgumentError) { Rgpio::SoftwarePWM.new(18, chip: PipeChip.new(@levels_out), process: :yes) }
  end

  def test_a_failed_line_request_raises_from_new_in_the_parent
    chip = PipeChip.new(@levels_out, fail_with: Errno::EBUSY.new("GPIO18 is already in use"))
    error = assert_raises(Errno::EBUSY) { Rgpio::SoftwarePWM.new(18, chip: chip, process: true) }
    assert_match(/GPIO18 is already in use/, error.message)
  end

  def test_toggles_the_line_while_running
    channel = pwm(frequency: 500, duty_cycle: 0.5)
    channel.enable
    sleep 0.1
    channel.disable
    levels = drain

    assert_includes levels, "1"
    assert_includes levels, "0"
    refute_includes levels, "11", "every high must be followed by a low"
    assert levels.end_with?("0"), "disable must leave the line inactive"
  end

  def test_disable_stops_the_child_writing
    channel = pwm(frequency: 500, duty_cycle: 0.5)
    channel.enable
    sleep 0.05
    channel.disable
    drain
    sleep 0.05

    assert_equal "", drain
    refute_predicate channel, :enabled?
  end

  def test_settings_reach_the_running_child
    channel = pwm(frequency: 500, duty_cycle: 0.5)
    channel.enable
    sleep 0.05
    channel.duty_cycle = 0.0
    sleep 0.02
    drain
    sleep 0.05

    refute_includes drain, "1", "duty 0 must stop raising the line"
    channel.disable
  end

  def test_close_releases_the_line_and_reaps_the_child
    channel = pwm(frequency: 500, duty_cycle: 0.5)
    channel.enable
    pid = channel.instance_variable_get(:@pid)
    channel.close

    assert drain.end_with?("R"), "the child must release the line before exiting"
    assert_raises(Errno::ECHILD, Errno::ESRCH) { Process.kill(0, pid) && Process.wait(pid) }
    assert_predicate channel, :closed?
  end

  # The parent going away without close must still stop the child.
  def test_the_child_exits_when_its_pipe_closes
    channel = pwm(frequency: 500, duty_cycle: 0.5)
    channel.enable
    pid = channel.instance_variable_get(:@pid)
    channel.instance_variable_get(:@commands).close
    Process.wait(pid)

    assert drain.end_with?("R")
  end

  def test_a_second_channel_does_not_keep_the_first_alive
    first = pwm(frequency: 500, duty_cycle: 0.5)
    second_in, second_out = IO.pipe
    second = pwm(chip: PipeChip.new(second_out), frequency: 500, duty_cycle: 0.5)
    first_pid = first.instance_variable_get(:@pid)

    first.instance_variable_get(:@commands).close
    Timeout.timeout(2) { Process.wait(first_pid) }
    second.close
  ensure
    second_in&.close
    second_out&.close
  end

  def test_inspect_says_process
    assert_match(/ process/, pwm(frequency: 100).inspect)
  end
end
