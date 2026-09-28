# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

First development release (targeting `0.1.0`). Not yet published to RubyGems.

### Added

- **GPIO character-device I/O via libgpiod v2** (`Rgpio::Chip`, `Rgpio::LineRequest`)
  bound through the stdlib `fiddle`, so it works on every Pi including ARMv6
  boards (Pi Zero / Pi 1) where the precompiled `ffi` gem crashes.
- `Rgpio::Chip.open` / `.new` with block form that closes the chip on exit.
- Line requests with `direction`, `edge`, `bias`, `active_low`, `debounce_us`,
  `initial_value`, and `consumer` options.
- Edge-event detection: `LineRequest#wait_edge_events` and `#read_edge_events`
  returning `{ type:, offset:, timestamp_ns: }` hashes.
- Automatic detection of the 40-pin header GPIO controller by chip label
  (`pinctrl-rp1` / `pinctrl-bcm2711` / `pinctrl-bcm2835`), so the same code
  targets Pi 5 / Pi 4 / Pi Zero without changes. `Rgpio::Chip.list` and
  `.detect_path` expose the selection.
- **Hardware PWM via the Linux PWM sysfs interface** (`Rgpio::HardwarePWM`) with
  no FFI required. Supports `frequency=`, `duty_cycle=`, `pulse_width_us=`,
  `enable`/`disable`, and block-form `.open`.
- Automatic RP1 PWM chip/channel detection on Pi 5, including `gpio:`-based
  channel lookup for GPIO12/13/18/19 and a udev-race-safe channel export.
- Board-aware hardware PWM: `HardwarePWM.detect_board` reads the device-tree
  model, and `.new(gpio:, board:)` maps header pins to channels per board.
  Verified on both Pi 5 (RP1) and Pi 4 (BCM2711, chip at `fe20c000`, 2 channels).
  `#board` exposes the resolved family.
- `examples/pwm_info.rb`: a non-destructive diagnostic that prints the detected
  board, the PWM chips in sysfs, and which chip/channel each header GPIO resolves
  to — without exporting anything.
- **High-level device API** (`Rgpio::LED`, `Button`, `MotionSensor`, `Motor`,
  and the `OutputDevice` / `InputDevice` bases they are built on), a
  gpiozero-style layer over `Chip` / `LineRequest`. Devices open their own chip
  or share one passed as `chip:`, and `#close` releases only what they own.
- Edge callbacks on input devices — `button.when_pressed { }`,
  `sensor.when_motion { }` — dispatched from a background watcher thread that
  survives a raising callback, plus `Rgpio.pause` as the counterpart to Python's
  `signal.pause()`.
- **I2C support via the Linux i2c-dev interface** (`Rgpio::I2C`): `write`,
  `read`, `write_read` (repeated START), `read_register` / `write_register`,
  block-form `.open`, and `.buses`. Built on `ioctl` against `/dev/i2c-N`, so it
  needs no libgpiod and works wherever `Rgpio.available?` is false. Verified on
  Pi 5 against an EEPROM (128-byte EDID read, valid checksum).
- **I2C device drivers**: `Rgpio::ADT7410` (temperature sensor — 13/16-bit
  resolution, `#temperature`, `#detected?`) and `Rgpio::ST7032` (AQM0802 /
  AQM1602 character LCD — `#message=`, `#print`, `#move_to`, `#contrast=`,
  `#display_on` / `#display_off`). Both take an `i2c:` to share a bus device, or
  open their own. Verified on Pi 5 with both modules on the header bus at once.
- `examples/temperature.rb`, `lcd.rb`, `lcd_thermometer.rb`: I2C examples.
- **SPI support via the Linux spidev interface** (`Rgpio::SPI`): full-duplex
  `transfer`, `write`, `read`, `mode=`, `speed_hz=`, `bits_per_word=`, block-form
  `.open` and `.devices`. Like the I2C support it is `ioctl` work on a character
  device, so it needs no libgpiod.
- **`Rgpio::MCP3208`**: eight 12-bit ADC channels (`read` for the raw code,
  `value` for a ratio, `voltage` for volts, `read_all`, plus differential pairs).
  `channels: 4` covers the MCP3204, which shares the protocol.
- `examples/adc.rb` prints every channel; `examples/adc_led.rb` dims an LED from
  a potentiometer, tying the ADC to `PWMLED`.
- **Software PWM** (`Rgpio::SoftwarePWM`): PWM generated in Ruby on any GPIO
  line, with no dtoverlay and no config.txt entry. `frequency=`, `duty_cycle=`,
  `pulse_width_us=`, `enable`/`disable`, block-form `.open` — the same interface
  as `HardwarePWM`, so the device classes take either. The generating thread
  sleeps until shortly before each edge and then spins, capped at 5% of the
  period. Measured on a Pi 5: a 50 Hz 1500 us pulse held to 6 us of standard
  deviation for 2.7% of one core.
- **PWM-backed devices**: `Rgpio::PWMLED` (brightness), `Rgpio::RGBLED` (three
  channels, named colours, common-anode support via `active_low:`) and
  `Rgpio::Servo` (`value`, `angle`, `min`/`mid`/`max`, `detach`, calibratable
  pulse range). All default to software PWM and take `pwm: :hardware` — or a
  channel object — to drive the PWM peripheral instead. `RGBLED` takes a
  `balance:` scale per channel, because an RGB LED's three dies are not equally
  bright for equal duty and its white comes out tinted without one.
- `examples/pwm_led.rb`, `rgb_led.rb`, `servo.rb`: PWM device examples.
  `examples/pwm_jitter.rb` measures the waveform a PWM channel really produces,
  using the kernel's edge timestamps and a jumper between two header pins.
- `examples/led.rb`, `button.rb`, `motion_sensor.rb`, `motor.rb`: device-class
  examples. The `Chip` / `LineRequest` versions of the LED and button demos moved
  to `examples/lowlevel/`, so the top level shows the API most users want first.

### Changed

- `require "rgpio"` no longer crashes on systems that ship libgpiod 1.x (e.g.
  Debian Bookworm, where it is `libgpiod.so.2`): the loader now probes for a
  libgpiod v2 symbol and reports `Rgpio.available? == false` instead of raising
  when only v1 is present. The sysfs-only `HardwarePWM` stays usable there.
- `Rgpio.available?` / `.version` helpers for probing the libgpiod library.
- Examples: `examples/blink.rb`, `examples/button.rb`. The `HardwarePWM` servo
  demo moved to `examples/lowlevel/servo.rb`, since the top-level `servo.rb` now
  shows the `Servo` device class.
- Minitest suite covering chip-selection logic and PWM helpers.

[Unreleased]: https://github.com/lumbermill/rgpio/commits/main
