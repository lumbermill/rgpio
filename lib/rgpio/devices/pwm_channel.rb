module Rgpio
  # Shared by the PWM-backed devices ({PWMOutputDevice}, {Servo}): turns the
  # `pwm:` option into a channel to drive the line with.
  #
  # A symbol means the device opens — and later closes — a channel of its own:
  #
  # - `:auto` (the default) — {HardwarePWM} on GPIO12/13/18/19 when a dtoverlay
  #   has routed the pin to the PWM peripheral, {SoftwarePWM} otherwise. A
  #   hardware-capable pin left on software PWM prints a one-time warning naming
  #   the overlay that would fix it.
  # - `:hardware` / `:software` — that one, with no warning.
  #
  # Anything else is a channel the caller owns and keeps, so that several devices
  # can share one, or a {HardwarePWM} already configured the way they want it.
  #
  # `:auto` reads the line's state rather than checking for a PWM chip. A chip
  # exists as soon as any PWM overlay is loaded, but only the pins the overlay
  # names are connected to it: with `pwm-2chan` on 18/19, GPIO12 would export
  # channel 0 and output nothing on a Pi 5, and on a Pi 4 / Zero — where 12 and
  # 18 share channel 0 — drive GPIO18 instead. A pin the overlay names is held
  # by the kernel (in use, with no consumer), which is also why software PWM
  # could not request it; a free pin is not connected to the peripheral, which
  # is why hardware PWM could not drive it. Either way, the choice is the only
  # one that can work.
  module PWMChannel
    # The header pins the PWM peripheral reaches, with the dtoverlay line that
    # routes each one. The pin numbers and Alt functions are the same on the
    # Pi 5, Pi 4 and Pi Zero.
    HARDWARE_PWM_OVERLAYS = {
      12 => "dtoverlay=pwm,pin=12,func=4",
      13 => "dtoverlay=pwm,pin=13,func=4",
      18 => "dtoverlay=pwm,pin=18,func=2",
      19 => "dtoverlay=pwm,pin=19,func=2",
    }.freeze

    @warned = {}
    @warn_mutex = Mutex.new

    class << self
      # Which channel `pwm: :auto` uses for a line.
      #
      # @param gpio [Integer] GPIO line offset
      # @param info [Hash, nil] the line's {Chip#line_info}, or nil when it
      #   could not be read (no usable libgpiod, e.g. on Bookworm)
      # @return [:hardware, :software]
      def choose(gpio, info)
        return :software unless HARDWARE_PWM_OVERLAYS.key?(gpio)
        # Without line info, only hardware PWM can work at all: software PWM
        # needs libgpiod just as the lookup did.
        return :hardware if info.nil?

        info[:used] && info[:consumer].nil? ? :hardware : :software
      end

      # The warning for a hardware-capable pin left on software PWM.
      # @return [String, nil]
      def fallback_warning(gpio)
        overlay = HARDWARE_PWM_OVERLAYS[gpio]
        return nil unless overlay

        "rgpio: GPIO#{gpio} supports hardware PWM, but no dtoverlay routes it to the " \
          "PWM peripheral, so software PWM is used. For jitter-free output add " \
          "`#{overlay}` to /boot/firmware/config.txt and reboot " \
          "(#{HardwarePWM::GUIDE_URL}); pass pwm: :software to silence this."
      end

      # Print {fallback_warning} once per GPIO line per process.
      def warn_fallback(gpio)
        message = fallback_warning(gpio)
        return unless message
        return unless @warn_mutex.synchronize { @warned[gpio] ? false : (@warned[gpio] = true) }

        Kernel.warn(message)
      end

      # Forget which lines were warned about. For tests.
      def reset_warnings!
        @warn_mutex.synchronize { @warned.clear }
      end
    end

    private

    # @return [Array(Object, Boolean)] the channel, and whether it is ours to close
    def resolve_pwm(pwm, gpio:, frequency:, chip:, consumer:)
      return [pwm, false] unless pwm.is_a?(Symbol)

      case pwm
      when :auto
        if PWMChannel.choose(gpio, auto_line_info(gpio, chip)) == :hardware
          [open_hardware_pwm(gpio, frequency, auto: true), true]
        else
          PWMChannel.warn_fallback(gpio)
          [SoftwarePWM.new(gpio, frequency: frequency, chip: chip, consumer: consumer), true]
        end
      when :software
        [SoftwarePWM.new(gpio, frequency: frequency, chip: chip, consumer: consumer), true]
      when :hardware
        [open_hardware_pwm(gpio, frequency), true]
      else
        raise ArgumentError, "pwm must be :auto, :software, :hardware or a PWM channel, got #{pwm.inspect}"
      end
    end

    def open_hardware_pwm(gpio, frequency, auto: false)
      HardwarePWM.new(gpio: gpio).tap { |channel| channel.frequency = frequency }
    rescue PWMError => e
      raise unless auto

      raise PWMError, "GPIO#{gpio} is held by the kernel, so pwm: :auto chose hardware PWM, " \
                      "but it could not be opened: #{e.message}"
    end

    # Only the hardware-capable pins need looking up; the rest are always
    # software, so no chip is opened for them here.
    def auto_line_info(gpio, chip)
      return nil unless HARDWARE_PWM_OVERLAYS.key?(gpio)

      chip ? chip.line_info(gpio) : Chip.open { |c| c.line_info(gpio) }
    rescue Error, SystemCallError
      nil
    end
  end
end
