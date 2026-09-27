module Rgpio
  # PWM generated in Ruby on any GPIO line, for the pins the hardware PWM
  # peripheral cannot reach.
  #
  # {HardwarePWM} is jitter-free but needs a dtoverlay in config.txt and only
  # reaches GPIO12/13/18/19, two channels at a time on the 40-pin header. This
  # class needs no configuration at all and works on every line, at the cost of
  # timing accuracy — the same trade-off Python's gpiozero makes, which drives
  # all of its PWM through `lgpio.tx_pwm` ("software timed PWM").
  #
  # Usage (block form — recommended):
  #   Rgpio::SoftwarePWM.open(18) do |pwm|
  #     pwm.frequency  = 100
  #     pwm.duty_cycle = 0.25
  #     pwm.enable
  #     sleep 2
  #   end
  #
  # Accuracy: the generating thread sleeps until shortly before each edge and
  # then spins for the last {#spin_us} microseconds, because a bare `sleep`
  # overshoots a microsecond-scale deadline badly — with no spin at all, a 50 Hz
  # 1500 us pulse measured on a Pi 5 spread over 72..6756 us. Spinning holds the
  # GVL, so it is a tax on the main thread, capped at {MAX_SPIN_FRACTION} of the
  # period per edge.
  #
  # Nothing can fix the other direction: while the main thread holds the GVL in
  # a long computation, this thread cannot wake at all. Python has the same
  # limitation with the GIL.
  class SoftwarePWM
    # gpiozero's default for PWMLED, and fast enough that an LED does not
    # visibly flicker.
    DEFAULT_FREQUENCY = 100

    # How long before each edge to stop sleeping and start spinning. Measured
    # on a Pi 5 at 50 Hz: 0 us gives a 386 us standard deviation and pulses as
    # long as 6.7 ms, 100 us gives 29 us, 300 us gives 13 us, and 1000 us is no
    # better than 300.
    DEFAULT_SPIN_US = 300

    # Cap on the spin as a fraction of the period, per edge. Spinning holds the
    # GVL, so a fixed 300 us would cost 60% of a core at 1 kHz; this keeps the
    # tax at 10% of one core whatever the frequency, and a frequency that high
    # is driving an LED, where a few microseconds of edge placement is invisible.
    MAX_SPIN_FRACTION = 0.05

    # The range lgpio accepts, for parity. Above roughly 1 kHz the duty cycle
    # of a Ruby-generated waveform stops being accurate — measure before
    # trusting it.
    FREQUENCY_RANGE = (0.1..10_000)

    # Open a channel, yield it, then close it.
    # @return [SoftwarePWM, Object] the channel, or the block's value
    def self.open(gpio, **)
      pwm = new(gpio, **)
      return pwm unless block_given?

      begin
        yield pwm
      ensure
        pwm.close
      end
    end

    # @param gpio       [Integer] GPIO line offset (BCM numbering)
    # @param frequency  [Numeric] Hz
    # @param duty_cycle [Float] 0.0..1.0
    # @param spin_us    [Integer] microseconds to spin before each edge
    # @param chip       [Chip, nil] chip to share, or nil to open one
    # @param consumer   [String] name shown in the kernel's request list
    def initialize(gpio, frequency: DEFAULT_FREQUENCY, duty_cycle: 0.0, spin_us: DEFAULT_SPIN_US,
                   chip: nil, consumer: "rgpio")
      @gpio = gpio
      @spin = validate_spin(spin_us) / 1_000_000.0
      @mutex = Mutex.new
      @frequency = validate_frequency(frequency)
      @duty = validate_duty(duty_cycle)
      @running = false
      @closed = false
      @owns_chip = chip.nil?
      @chip = chip || Chip.new
      @request = @chip.request_lines(
        offsets: [gpio],
        direction: :output,
        initial_value: :inactive,
        consumer: consumer
      )
    end

    # @return [Integer] the GPIO line this channel drives
    attr_reader :gpio

    # @return [Numeric] frequency in Hz
    attr_reader :frequency

    # @return [Float] duty cycle as a ratio, 0.0..1.0
    def duty_cycle
      @duty
    end

    # Alias for parity with {HardwarePWM}, which calls it duty_ratio.
    alias duty_ratio duty_cycle

    # @return [Integer] microseconds spent spinning before each edge
    def spin_us
      (@spin * 1_000_000).round
    end

    def frequency=(hz)
      hz = validate_frequency(hz)
      @mutex.synchronize { @frequency = hz }
      hz
    end

    def duty_cycle=(ratio)
      ratio = validate_duty(ratio)
      @mutex.synchronize { @duty = ratio }
      ratio
    end

    # Set the high time directly, the way a servo is addressed.
    # @param us [Numeric] pulse width in microseconds
    def pulse_width_us=(us)
      raise ArgumentError, "pulse width must not be negative, got #{us}" if us.negative?

      self.duty_cycle = us / period_us
    end

    # @return [Float] current pulse width in microseconds
    def pulse_width_us
      @duty * period_us
    end

    # Start generating. Safe to call when already running.
    def enable
      raise Error, "SoftwarePWM on GPIO#{@gpio} is closed" if @closed
      return self if @running

      @running = true
      @thread = Thread.new { generate }
      self
    end

    # Stop generating and leave the line inactive.
    def disable
      return self unless @running

      @running = false
      @thread&.join
      @thread = nil
      @request.set_value(@gpio, :inactive)
      self
    end

    def enabled?
      @running
    end

    # Stop, release the line, and close the chip if this channel opened it.
    # Safe to call multiple times.
    def close
      return if @closed

      disable
      @closed = true
      @request.release
      @chip.close if @owns_chip
    end

    def closed?
      @closed
    end

    def inspect
      format("#<%s gpio=%d frequency=%gHz duty_cycle=%.3f%s>",
             self.class, @gpio, @frequency, @duty, @running ? " running" : "")
    end

    private

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def period_us
      1_000_000.0 / @frequency
    end

    # The generating loop. Deadlines are absolute so that a late wake-up does
    # not push every later edge back by the same amount.
    #
    # The settings are re-read after the falling edge rather than before the
    # rising one: any work done between the deadline and the rising edge is
    # taken straight out of the high time, and reading them under the mutex
    # cost a measurable 17 us of every pulse when it sat there.
    def generate
      period = high = nil
      read_settings do |p, h|
        period = p
        high = h
      end
      spin = effective_spin(period)
      deadline = now

      while @running
        # A line that is fully on or fully off needs no edges at all, and
        # toggling it anyway would put a one-cycle glitch in the output.
        if high <= 0 || high >= period
          @request.set_value(@gpio, high <= 0 ? :inactive : :active)
        else
          # Time the high phase from the edge that actually happened, not from
          # the nominal deadline: the rise lands a little after it (waking from
          # the long low phase overshoots), and measuring from the deadline took
          # that lateness straight out of the pulse — a measured 15 us of every
          # one. The period stays locked to the absolute deadline below, so only
          # the falling edge's phase drifts, which nothing can observe.
          #
          # The clock is read *before* each set_value so that the call's own
          # latency cancels: it delays both edges by the same amount.
          # Warm the call path with a write of the level the line already holds:
          # the first set_value after waking from the long low phase is both slow
          # and erratic (cold cache, possibly another core), and that lands
          # entirely inside the pulse. Paying it before the clock read leaves the
          # real edge to a warm path.
          @request.set_value(@gpio, :inactive)
          rise = now
          @request.set_value(@gpio, :active)
          wait_until(rise + high, spin)
          @request.set_value(@gpio, :inactive)
        end

        deadline += period
        read_settings do |p, h|
          period = p
          high = h
        end
        # If the thread was starved for longer than a whole cycle, catching up
        # would mean running with no waits at all. Give up the lost cycles.
        deadline = now if deadline < now - period
        spin = effective_spin(period)
        wait_until(deadline, spin)
      end
    rescue StandardError => e
      warn "rgpio: SoftwarePWM on GPIO#{@gpio} stopped: #{e.class}: #{e.message}"
    ensure
      @running = false
    end

    # The spin is capped relative to the period so that a high frequency cannot
    # turn the generating thread into a busy loop.
    def effective_spin(period)
      [@spin, period * MAX_SPIN_FRACTION].min
    end

    # Yield the period and high time in seconds. Kept allocation-free: building
    # a two-element array here showed up as jitter.
    def read_settings
      @mutex.synchronize { yield 1.0 / @frequency, @duty / @frequency }
    end

    # Sleep for the bulk of the wait, then spin: sleep alone overshoots a
    # microsecond-scale deadline by more than the pulse widths we are aiming for.
    def wait_until(target, spin)
      coarse = target - now - spin
      sleep coarse if coarse.positive?
      nil while now < target
    end

    def validate_frequency(hz)
      unless hz.is_a?(Numeric) && FREQUENCY_RANGE.cover?(hz)
        raise ArgumentError, "frequency must be in #{FREQUENCY_RANGE} Hz, got #{hz.inspect}"
      end

      hz
    end

    def validate_duty(ratio)
      unless ratio.is_a?(Numeric) && (0.0..1.0).cover?(ratio)
        raise ArgumentError, "duty cycle must be in 0.0..1.0, got #{ratio.inspect}"
      end

      ratio.to_f
    end

    def validate_spin(us)
      raise ArgumentError, "spin_us must not be negative, got #{us}" unless us.is_a?(Numeric) && !us.negative?

      us
    end
  end
end
