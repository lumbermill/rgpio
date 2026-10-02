module Rgpio
  # A resistive touch panel read through an XPT2046 (or ADS7843/TSC2046)
  # controller over SPI — the touch half of the common 2.4"/2.8" ILI9341
  # modules, on the same bus as the display with a chip select of its own.
  #
  #   touch = Rgpio::XPT2046.new(irq: 17, calibration: [...])
  #   touch.when_touched  { |x, y| puts "#{x}, #{y}" }
  #   touch.when_released { puts "released" }
  #   Rgpio.pause
  #
  # #raw returns the converter's 12-bit readings. Turning those into screen
  # coordinates needs a calibration, since the film's resistance and how it is
  # mounted vary from panel to panel: {.calibration_from} fits one from a few
  # touches on known screen points. With no calibration, #position is the raw
  # [x, y].
  #
  # T_IRQ (PENIRQ) goes low while the panel is pressed. It is optional: with
  # it, the watcher thread sleeps on a kernel edge event until a touch; without
  # it, the watcher samples the pressure every POLL_INTERVAL.
  class XPT2046
    DEFAULT_SPEED_HZ = 2_000_000

    # Control byte: start bit, channel (A2..A0), 12-bit mode, differential
    # reference, and power-down between conversions with PENIRQ enabled.
    CMD_X = 0xd0
    CMD_Y = 0x90
    CMD_Z1 = 0xb0
    CMD_Z2 = 0xc0

    RESOLUTION = 4096

    # Pressure (on the scale of #raw's z) below which the panel counts as not
    # touched. Lower it for a light touch, raise it if the panel reports touches
    # nobody made.
    DEFAULT_THRESHOLD = 300

    # Readings per coordinate; the median of them is used, which rejects the
    # odd sample taken while a finger is landing or lifting.
    SAMPLES = 5

    # How often a held touch is re-read to notice its release, and how often
    # the pressure is polled with no T_IRQ line.
    POLL_INTERVAL = 0.02

    # How long a single edge wait blocks before the watcher rechecks whether it
    # has been asked to stop.
    WATCH_TIMEOUT = 0.2

    # Fit a calibration from touches on known screen points: a least-squares
    # affine map, so a panel mounted rotated or mirrored needs nothing extra.
    # Three points not on one line is the minimum; the four corners and the
    # centre average out the error of each touch.
    # @param screen [Array<Array(Numeric, Numeric)>] screen [x, y] of each target
    # @param raw    [Array<Array(Numeric, Numeric)>] raw [x, y] touched there
    # @return [Array<Float>] [a, b, c, d, e, f] with x = a*rx + b*ry + c and
    #   y = d*rx + e*ry + f
    def self.calibration_from(screen, raw)
      raise ArgumentError, "calibration needs the same number of screen and raw points" unless screen.size == raw.size
      raise ArgumentError, "calibration needs at least three points" if screen.size < 3

      rows = raw.map { |rx, ry| [rx.to_f, ry.to_f, 1.0] }
      solve_least_squares(rows, screen.map { |sx, _| sx.to_f }) +
        solve_least_squares(rows, screen.map { |_, sy| sy.to_f })
    end

    # Solve rows * coef ~= targets for three coefficients through the normal
    # equations.
    def self.solve_least_squares(rows, targets)
      matrix = normal_equations(rows, targets)
      3.times do |col|
        pivot = (col...3).max_by { |row| matrix[row][col].abs }
        raise ArgumentError, "calibration points must not all lie on one line" if matrix[pivot][col].abs < 1e-9

        matrix[col], matrix[pivot] = matrix[pivot], matrix[col]
        (0...3).each do |row|
          next if row == col

          factor = matrix[row][col] / matrix[col][col]
          4.times { |k| matrix[row][k] -= factor * matrix[col][k] }
        end
      end
      Array.new(3) { |i| matrix[i][3] / matrix[i][i] }
    end

    # @return [Array<Array<Float>>] the augmented 3x4 matrix [AᵀA | Aᵀt]
    def self.normal_equations(rows, targets)
      Array.new(3) do |i|
        Array.new(3) { |j| rows.sum { |r| r[i] * r[j] } } + [rows.each_with_index.sum { |r, k| r[i] * targets[k] }]
      end
    end
    private_class_method :solve_least_squares, :normal_equations

    # @param irq         [Integer, nil] GPIO line wired to T_IRQ, or nil to poll
    # @param calibration [Array<Numeric>, nil] six numbers from {.calibration_from}
    # @param threshold   [Integer] pressure that counts as a touch
    # @param bus         [Integer] spidev bus number
    # @param device      [Integer] chip-select index; CE1 when the display is on CE0
    # @param speed_hz    [Integer] clock rate
    # @param spi         [SPI, nil] an open bus device to share, or nil to open one
    # @param chip        [Chip, nil] chip for the T_IRQ line, or nil to open one
    # @param consumer    [String] name shown in the kernel's request list
    def initialize(irq: nil, calibration: nil, threshold: DEFAULT_THRESHOLD, bus: 0, device: 1,
                   speed_hz: DEFAULT_SPEED_HZ, spi: nil, chip: nil, consumer: "rgpio")
      self.calibration = calibration
      @threshold = threshold
      @callbacks = {}
      @closed = false
      @lock = Mutex.new
      @owns_spi = spi.nil?
      @spi = spi || SPI.new(bus: bus, device: device, speed_hz: speed_hz, mode: 0)
      @irq = irq
      return unless irq

      @owns_chip = chip.nil?
      @chip = chip || Chip.new
      # PENIRQ is open drain; the boards have no pull-up of their own.
      @irq_request = @chip.request_lines(offsets: [irq], direction: :input, edge: :falling, bias: :pull_up,
                                         consumer: consumer)
    end

    # @return [SPI] the bus device readings go through
    attr_reader :spi

    # @return [Array<Float>, nil] the calibration in use
    attr_reader :calibration

    # @return [Integer] pressure that counts as a touch
    attr_accessor :threshold

    # @param coefficients [Array<Numeric>, nil] six numbers from {.calibration_from}
    def calibration=(coefficients)
      unless coefficients.nil? || (coefficients.is_a?(Array) && coefficients.size == 6 && coefficients.all?(Numeric))
        raise ArgumentError, "calibration is six numbers from XPT2046.calibration_from, got #{coefficients.inspect}"
      end

      @calibration = coefficients&.map(&:to_f)&.freeze
    end

    # @return [Array(Integer, Integer, Integer)] raw x, y (0..4095) and
    #   pressure z (0 when untouched, larger the harder the press)
    def raw
      raise Error, "#{self.class} is closed" if @closed

      @lock.synchronize do
        # Pressure is read on both sides of the position and the lower one
        # kept: a pen landing or lifting part-way through leaves x/y unsettled
        # (or at the untouched 0/4095), and one of the two pressures reads low.
        z_before = read_pressure
        # The first conversion after the drivers switch on is still settling.
        read_channel(CMD_X)
        x = median(SAMPLES) { read_channel(CMD_X) }
        y = median(SAMPLES) { read_channel(CMD_Y) }
        [x, y, [z_before, read_pressure].min]
      end
    end

    # @return [Boolean] whether the panel is pressed at least #threshold hard
    def touched?
      raw[2] >= @threshold
    end

    # @return [Array(Integer, Integer), nil] the touch in screen coordinates,
    #   or nil when untouched
    def position
      x, y, z = raw
      z >= @threshold ? to_screen(x, y) : nil
    end

    # @yieldparam x [Integer] screen x of the touch
    # @yieldparam y [Integer] screen y of the touch
    def when_touched(&)
      on(:touched, &)
    end

    def when_released(&)
      on(:released, &)
    end

    # Stop the watcher, then release the T_IRQ line, the bus and the chip as
    # far as this object opened them.
    def close
      return if @closed

      @closed = true
      @watching = false
      @watcher&.join
      @watcher = nil
      @irq_request&.release
      @spi.close if @owns_spi
      @chip.close if @owns_chip
    end

    def closed?
      @closed
    end

    private

    # The 12-bit result arrives MSB first after the command byte, left-aligned
    # with three trailing zero bits.
    def read_channel(cmd)
      received = @spi.transfer([cmd, 0x00, 0x00])
      ((received[1] << 8) | received[2]) >> 3
    end

    def read_pressure
      read_channel(CMD_Z1) + (RESOLUTION - 1) - read_channel(CMD_Z2)
    end

    def median(count, &)
      Array.new(count, &).sort[count / 2]
    end

    def to_screen(x, y)
      return [x, y] unless @calibration

      a, b, c, d, e, f = @calibration
      [((a * x) + (b * y) + c).round, ((d * x) + (e * y) + f).round]
    end

    def on(kind, &block)
      raise ArgumentError, "a callback block is required" unless block

      @callbacks[kind] = block
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
        touch = wait_for_touch
        follow_touch(*touch) if touch
      end
    rescue StandardError => e
      warn "rgpio: touch watcher stopped: #{e.class}: #{e.message}"
    end

    # @return [Array(Integer, Integer), nil] where the panel is pressed, once it is
    def wait_for_touch
      if @irq_request
        return nil if @irq_request.read_edge_events(timeout: WATCH_TIMEOUT).empty?
      else
        sleep(POLL_INTERVAL)
      end
      position
    end

    # Report a touch, then poll until it lifts. Conversions make PENIRQ drop
    # again while the pen is down, so the edges queued meanwhile are discarded
    # rather than read as new touches.
    def follow_touch(x, y)
      dispatch(:touched, x, y)
      sleep(POLL_INTERVAL) while @watching && touched?
      dispatch(:released)
      drain_edges
    end

    def drain_edges
      return unless @irq_request

      nil until @irq_request.read_edge_events(timeout: 0).empty?
    end

    # A raising callback must not take the watcher down with it.
    def dispatch(kind, *)
      callback = @callbacks[kind]
      return unless callback

      callback.call(*)
    rescue StandardError => e
      warn "rgpio: #{self.class} #{kind} callback raised #{e.class}: #{e.message}"
    end
  end
end
