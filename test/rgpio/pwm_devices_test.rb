require_relative "../test_helper"
require "rgpio"

# Hardware-free tests for the PWM-backed devices. Each takes a `pwm:` channel,
# so a fake one stands in for SoftwarePWM here: no GPIO, no threads, and the
# duty cycles and pulse widths the device asks for are visible directly.
class PWMDevicesTest < Minitest::Test
  # Records what a device asks of its channel, in order.
  class FakePWM
    attr_reader :duty_cycles, :pulse_widths, :events, :frequency

    def initialize(frequency: 100)
      @frequency = frequency
      @duty_cycles = []
      @pulse_widths = []
      @events = []
    end

    def frequency=(hz)
      @frequency = hz
      @events << :frequency
    end

    def duty_cycle=(ratio)
      @duty_cycles << ratio
      @events << :duty
    end

    def duty_cycle
      @duty_cycles.last
    end

    def pulse_width_us=(us)
      @pulse_widths << us
      @events << :pulse
    end

    def pulse_width_us
      @pulse_widths.last
    end

    def enable
      @events << :enable
    end

    def disable
      @events << :disable
    end

    def close
      @events << :close
    end
  end

  # --- PWMOutputDevice / PWMLED -------------------------------------------

  def test_sets_the_level_before_starting_the_channel
    channel = FakePWM.new
    Rgpio::PWMLED.new(4, initial_value: 0.25, pwm: channel)

    assert_equal [0.25], channel.duty_cycles
    assert_equal %i[duty enable], channel.events, "the line must hold its level before output starts"
  end

  def test_value_drives_the_duty_cycle
    channel = FakePWM.new
    led = Rgpio::PWMLED.new(4, pwm: channel)
    led.value = 0.4

    assert_in_delta 0.4, led.value
    assert_in_delta 0.4, channel.duty_cycle
    assert_in_delta 0.4, led.brightness
  end

  def test_active_low_inverts_the_duty_cycle
    channel = FakePWM.new
    led = Rgpio::PWMLED.new(4, active_low: true, pwm: channel)
    led.value = 0.25

    assert_in_delta 0.25, led.value, 0.001, "the level is what the caller asked for"
    assert_in_delta 0.75, channel.duty_cycle, 0.001, "the line is driven the other way about"
  end

  def test_on_off_and_toggle
    channel = FakePWM.new
    led = Rgpio::PWMLED.new(4, pwm: channel)
    led.on

    assert_in_delta 1.0, led.value
    assert_predicate led, :on?
    led.off

    assert_in_delta 0.0, led.value
    refute_predicate led, :on?

    led.value = 0.25
    led.toggle

    assert_in_delta 0.75, led.value, 0.001, "toggle inverts the level rather than blanking it"
  end

  def test_rejects_a_level_outside_0_to_1
    led = Rgpio::PWMLED.new(4, pwm: FakePWM.new)

    assert_raises(ArgumentError) { led.value = 1.5 }
    assert_raises(ArgumentError) { led.value = -0.1 }
    assert_raises(ArgumentError) { led.value = "bright" }
  end

  def test_frequency_is_delegated_to_the_channel
    channel = FakePWM.new(frequency: 100)
    led = Rgpio::PWMLED.new(4, pwm: channel)
    led.frequency = 400

    assert_in_delta 400, led.frequency
    assert_in_delta 400, channel.frequency
  end

  def test_a_borrowed_channel_is_stopped_but_not_closed
    channel = FakePWM.new
    led = Rgpio::PWMLED.new(4, pwm: channel)
    led.close

    assert_predicate led, :closed?
    assert_includes channel.events, :disable
    refute_includes channel.events, :close
  end

  def test_closing_twice_is_harmless_and_setting_a_level_afterwards_raises
    led = Rgpio::PWMLED.new(4, pwm: FakePWM.new)
    led.close
    led.close

    assert_raises(Rgpio::Error) { led.value = 0.5 }
  end

  def test_rejects_an_unknown_channel_kind
    assert_raises(ArgumentError) { Rgpio::PWMLED.new(4, pwm: :magic) }
  end

  # --- RGBLED -------------------------------------------------------------

  def rgb(**)
    @channels = { red: FakePWM.new, green: FakePWM.new, blue: FakePWM.new }
    Rgpio::RGBLED.new(red: 2, green: 3, blue: 4, pwm: @channels, **)
  end

  def test_each_colour_gets_its_own_channel
    led = rgb

    assert_equal [0.0, 0.0, 0.0], led.color
    led.color = [1.0, 0.5, 0.0]

    assert_in_delta 1.0, @channels[:red].duty_cycle
    assert_in_delta 0.5, @channels[:green].duty_cycle
    assert_in_delta 0.0, @channels[:blue].duty_cycle
    assert_equal [1.0, 0.5, 0.0], led.color
  end

  def test_a_colour_can_be_named
    led = rgb
    led.color = :magenta

    assert_equal [1.0, 0.0, 1.0], led.color

    led.color = :off

    assert_equal [0.0, 0.0, 0.0], led.color
    refute_predicate led, :on?
  end

  def test_on_is_white_and_off_is_dark
    led = rgb
    led.on

    assert_equal [1.0, 1.0, 1.0], led.color
    assert_predicate led, :on?
    led.off

    assert_equal [0.0, 0.0, 0.0], led.color
  end

  def test_individual_channels_can_be_set_and_read
    led = rgb
    led.red = 0.5
    led.green = 0.25
    led.blue = 1.0

    assert_in_delta 0.5, led.red
    assert_in_delta 0.25, led.green
    assert_in_delta 1.0, led.blue
  end

  def test_active_low_inverts_every_channel
    led = rgb(active_low: true)
    led.color = :red

    assert_in_delta 0.0, @channels[:red].duty_cycle
    assert_in_delta 1.0, @channels[:green].duty_cycle
    assert_equal [1.0, 0.0, 0.0], led.color
  end

  def test_rejects_a_malformed_colour
    led = rgb

    assert_raises(ArgumentError) { led.color = [1.0, 0.0] }
    assert_raises(ArgumentError) { led.color = :octarine }
  end

  def test_balance_scales_the_channels_without_changing_the_reported_colour
    led = rgb(balance: [0.7, 1.0, 0.6])
    led.color = :white

    assert_equal [1.0, 1.0, 1.0], led.color, "the colour asked for is what is reported"
    assert_in_delta 0.7, @channels[:red].duty_cycle
    assert_in_delta 1.0, @channels[:green].duty_cycle
    assert_in_delta 0.6, @channels[:blue].duty_cycle
  end

  def test_balance_can_be_retuned_while_a_colour_is_showing
    led = rgb
    led.color = :white
    led.balance = [0.5, 1.0, 0.5]

    assert_in_delta 0.5, @channels[:red].duty_cycle
    assert_equal [1.0, 1.0, 1.0], led.color
    assert_equal [0.5, 1.0, 0.5], led.balance
  end

  def test_balance_applies_to_a_partial_level_too
    led = rgb(balance: [1.0, 1.0, 0.5])
    led.blue = 0.4

    assert_in_delta 0.2, @channels[:blue].duty_cycle
    assert_in_delta 0.4, led.blue
  end

  def test_rejects_a_malformed_balance
    assert_raises(ArgumentError) { rgb(balance: [1.0, 1.0]) }
    assert_raises(ArgumentError) { rgb(balance: [1.0, 1.0, 1.5]) }
  end

  def test_toggle_inverts_the_requested_colour
    led = rgb
    led.color = [1.0, 0.25, 0.0]
    led.toggle

    assert_equal [0.0, 0.75, 1.0], led.color
  end

  def test_closing_stops_every_channel
    led = rgb
    led.close

    assert_predicate led, :closed?
    assert(@channels.each_value.all? { |channel| channel.events.include?(:disable) })
  end

  # --- Servo --------------------------------------------------------------

  def servo(**)
    @servo_pwm = FakePWM.new(frequency: 50)
    Rgpio::Servo.new(12, pwm: @servo_pwm, **)
  end

  def test_starts_centred_on_a_1500_us_pulse
    unit = servo

    assert_in_delta 0.0, unit.value
    assert_in_delta 1500, @servo_pwm.pulse_width_us
    assert_predicate unit, :attached?
    assert_equal %i[pulse enable], @servo_pwm.events
  end

  def test_the_travel_ends_map_to_the_pulse_range
    unit = servo
    unit.min

    assert_in_delta 1000, @servo_pwm.pulse_width_us
    assert_in_delta(-1.0, unit.value)

    unit.max

    assert_in_delta 2000, @servo_pwm.pulse_width_us
    unit.mid

    assert_in_delta 1500, @servo_pwm.pulse_width_us
  end

  def test_a_wider_pulse_range_is_honoured
    unit = servo(min_pulse_us: 500, max_pulse_us: 2500)
    unit.min

    assert_in_delta 500, @servo_pwm.pulse_width_us
    unit.value = 0.5

    assert_in_delta 2000, @servo_pwm.pulse_width_us
  end

  def test_angles_map_linearly_onto_the_travel
    unit = servo
    unit.angle = 45

    assert_in_delta 0.5, unit.value
    assert_in_delta 1750, @servo_pwm.pulse_width_us
    assert_in_delta 45, unit.angle

    unit.angle = -90

    assert_in_delta(-1.0, unit.value)
    assert_in_delta 1000, @servo_pwm.pulse_width_us
  end

  def test_a_custom_angle_range_maps_onto_the_same_travel
    unit = servo(min_angle: 0, max_angle: 180)
    unit.angle = 90

    assert_in_delta 0.0, unit.value
    assert_in_delta 1500, @servo_pwm.pulse_width_us
    assert_in_delta 90, unit.angle
  end

  def test_rejects_an_out_of_range_value_or_angle
    unit = servo

    assert_raises(ArgumentError) { unit.value = 1.5 }
    assert_raises(ArgumentError) { unit.angle = 120 }
    assert_raises(ArgumentError) { unit.pulse_width_us = 0 }
  end

  def test_rejects_a_pulse_range_that_is_not_a_range
    assert_raises(ArgumentError) { servo(min_pulse_us: 2000, max_pulse_us: 1000) }
  end

  def test_detaching_stops_the_pulses_and_forgets_the_position
    unit = servo
    unit.detach

    assert_in_delta 0.0, @servo_pwm.duty_cycle
    assert_nil unit.value
    assert_nil unit.angle
    assert_nil unit.pulse_width_us
    refute_predicate unit, :attached?
  end

  def test_starting_detached_sends_no_pulse
    unit = servo(initial_value: nil)

    refute_predicate unit, :attached?
    assert_empty @servo_pwm.pulse_widths
    assert_in_delta 0.0, @servo_pwm.duty_cycle
  end

  def test_a_raw_pulse_width_can_be_sent_for_calibration
    unit = servo
    unit.pulse_width_us = 2300

    assert_in_delta 2300, @servo_pwm.pulse_width_us
    assert_nil unit.value, "the position no longer follows from #value"
  end

  def test_closing_stops_a_borrowed_channel_without_closing_it
    unit = servo
    unit.close

    assert_predicate unit, :closed?
    assert_includes @servo_pwm.events, :disable
    refute_includes @servo_pwm.events, :close
    assert_raises(Rgpio::Error) { unit.value = 0.0 }
  end
end
