# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `Chip#line_info(offset)` returns `{offset:, used:, consumer:}` for one GPIO
  line, from libgpiod's line info.
- Loopback hardware tests (`rake integration`, with `RGPIO_LOOPBACK=<out>:<in>`
  naming two jumpered pins). They cover input/output levels, bias,
  `active_low`, batch I/O, edge events, line ownership and `LED` → `Button`
  callbacks. Verified on Pi 5 and on a Pi Zero W (ARMv6).
- `HardwarePWM` recognises the BCM2835 boards (Pi Zero, Zero W, Pi 1) as
  `board: :pi_zero`: two channels, GPIO12/18 on PWM0 and GPIO13/19 on PWM1,
  on the chip at `2020c000`. The guide gives the config.txt line. Verified on
  a Pi Zero W: 3000 pulses at 50 Hz / 1500 us showed no pulse more than 1 ms
  off, and a 4 us spread, which is the measurement's own noise.
- `examples/servo_with_hw.rb`: the `servo.rb` sweep from hardware PWM on
  GPIO12, with the config.txt line in its header comment.

### Changed

- `HardwarePWM` behaves like `SoftwarePWM` where the device layer sees both:
  `duty_cycle=` raises `ArgumentError` outside 0.0..1.0 instead of clamping,
  `pulse_width_us=` raises when negative or longer than the period, and
  `#duty_cycle` (reader) and `#closed?` exist. `HardwarePWM.open` and
  `Chip.open` return the instance when called without a block, like the
  other `open`s, instead of failing.
- Removed `HardwarePWM::GPIO_TO_PWM_CHANNEL_PI5`; use
  `GPIO_TO_PWM_CHANNEL[:pi5]`.
- `lib/rgpio/pwm.rb` is now `lib/rgpio/hardware_pwm.rb`, next to
  `software_pwm.rb`. Internal duplication is gone: `PWMOutputDevice` and
  `Servo` share a `PWMDevice` base class, the block-or-return `open` of
  `SoftwarePWM`, `I2C`, `SPI`, `ST7032` and `ILI9341` comes from one
  `Openable` module (so `I2C.open` now passes `force:` through as `I2C.new`
  takes it), and ioctl numbers and native buffers have one helper each
  (`Rgpio::Ioctl`, `Rgpio::Bytes.pointer`). Removed the `Native` bindings and
  buffer helpers that nothing used since values moved to ioctls
  (`gpiod_line_request_get_value` / `set_value` / `*_values_subset`,
  `int_buffer`, `int_output_buffer`, `read_int_buffer`), and the per-class
  ioctl constants they duplicated (`LineRequest::IOC_READ_WRITE`,
  `LineRequest.ioctl_number`, `SPI::IOC_WRITE`, `SPI::IOC_READ`).
- `PWMLED`, `RGBLED` and `Servo` default to `pwm: :auto`, which picks the
  channel from the pin: `HardwarePWM` on GPIO12/13/18/19 when a dtoverlay has
  routed the pin to the PWM peripheral (the kernel holds the line), and
  `SoftwarePWM` otherwise. A hardware-capable pin left on software PWM prints
  a one-time warning with the overlay line; `pwm: :software` forces software
  PWM and silences it, `pwm: :hardware` still forces the peripheral. The check
  is on the line, not on whether a PWM chip exists, because an overlay for
  other pins still creates the chip. Code that ran before keeps running: a pin
  routed to PWM could not be requested for software PWM anyway.
- On a single-core board (Pi Zero / Pi 1) `SoftwarePWM` generates the waveform
  in a forked child process (`process: :auto`; `true` / `false` to choose).
  The child disables the garbage collector and collects only inside the low
  phase. At 50 Hz on a Pi Zero, pulses more than 1 ms off went from 9-10 to
  3-6 a minute and the worst from 14 ms to 2-8 ms. A servo still trembles a
  little there, and the guide says so. The child exits, leaving the line
  inactive, when its parent closes the channel or exits. Multi-core boards
  keep the thread, so nothing changes on a Pi 4 or Pi 5. Adds
  `SoftwarePWM#process?`.
- `examples/servo.rb` ends with a hold (15 s, or the first argument) to watch
  for twitches, and says where its pulses come from.
- `LineRequest#get_value` / `#set_value` / `#get_values` / `#set_values` issue
  `GPIO_V2_LINE_GET_VALUES` / `SET_VALUES` with `IO#ioctl` on the request's file
  descriptor instead of calling libgpiod's value functions through fiddle. A
  fiddle call costs ~90 us on an ARMv6 Pi Zero, so `set_value` went from 158 us
  to 35 us there (3.9 us to 1.35 us on a Pi 5), and `set_value` allocates
  nothing. `SoftwarePWM`'s constant pulse offset on a Pi Zero halved
  (+62 us to +30 us at 50 Hz). An offset outside the request now raises
  `Errno::EINVAL` naming the request's offsets; the exception stays a
  `SystemCallError`, as before.
- `I2C` / `SPI` pack an all-integer byte list with one `pack` instead of one
  String per byte: a 4096-byte `SPI#transfer` of an Array went from 100 ms to
  29 ms on a Pi Zero. Results are unchanged, except that an empty list now
  packs to a binary rather than a US-ASCII empty string.
- The guide no longer promises `Errno::EREMOTEIO` for an I2C address nobody
  acknowledges: a Pi Zero's controller reports `Errno::EIO`.
- `examples/pwm_jitter.rb` drops its own priority to nice 19 while measuring,
  so on a single-core board it no longer steals the core from the generator.
- A failed `Chip#request_lines` now says which pin is taken and by whom. A pin
  held by I2C, SPI, UART or 1-Wire is refused by Raspberry Pi kernels from the
  6.18 series with `Errno::EINVAL`, which on its own read like a bad argument;
  the message now points at `config.txt` and `pinctrl get`. The exception class
  is unchanged. The "already in use by" case is checked on Pi 5 by the loopback
  tests; the kernel-function case is verified on a Pi with I2C enabled.
- The guide gains "Pins taken by another function", listing the pins each bus
  takes.

### Fixed

- `HardwarePWM` waits after export until `period`, `duty_cycle` and `enable`
  are all writable, not only `period`. The udev rule fixes their permissions
  one file at a time, and on a Pi Zero `Servo.new(12, pwm: :hardware)` failed
  with `EACCES` on `duty_cycle`.

## [0.1.1] - 2026-10-23

New devices for the Pi 5 round: a rotary encoder, and an SPI colour TFT with
its touch panel. All of them are verified on Pi 5.

### Added

- `Rgpio::RotaryEncoder` for quadrature encoders such as the KY-040:
  `steps` / `steps=` / `value`, `max_steps:` with optional `wrap:`, and
  `when_rotated` / `when_rotated_clockwise` / `when_rotated_counter_clockwise`
  callbacks, with `examples/rotary_encoder.rb`. Verified on Pi 5 with a bare
  three-pin encoder, no debounce needed.
- `Rgpio::ILI9341` for 240x320 SPI colour TFTs: `fill` / `fill_rect` /
  `pixel`, `blit` of raw RGB565, `text` in a built-in 5x7 font with `scale:`
  and optional background, `rotation=`, `invert=`, and an on/off or PWM
  `backlight=`. Drawing is clipped to the screen and safe from several threads.
  The SPI clock defaults to 24 MHz (20 MHz on a Pi 5; a full-screen fill takes
  about 65 ms). With `examples/tft.rb`. Verified on Pi 5.
- `Rgpio::XPT2046` for the resistive touch panel on the same modules: `raw`,
  `touched?`, `position`, `when_touched` / `when_released` (T_IRQ optional),
  and `XPT2046.calibration_from` to fit screen coordinates from a few touches.
  A reading taken while the pen lands or lifts is discarded. With
  `examples/touch_paint.rb` and `examples/ruby_stack.rb` (tap to drop rubies
  that pile up, in landscape). Verified on Pi 5.
- `Rgpio::RGB565` (colour names, `[r, g, b]` and RGB565 integers) and
  `Rgpio::Font5x7`, shared by the display classes.
- `SPI#send_bytes` sends a block of any length tx-only, split at
  `SPI.max_transfer_size` (spidev's `bufsiz`), without unpacking a reply.

## [0.1.0] - 2026-09-29

First release. GPIO, PWM, I2C and SPI on a Raspberry Pi from Ruby, with a
gpiozero-style device layer on top. Verified on Pi 5 and Pi 4 hardware; see
[PLAN.md](PLAN.md) for what has been measured on what, and for the parts still
waiting on hardware (Pi Zero / Pi 1, and `MotionSensor`).

### Added

- **GPIO character-device I/O via libgpiod v2** (`Rgpio::Chip`, `Rgpio::LineRequest`)
  bound through the stdlib `fiddle`. fiddle is built with the interpreter, so it
  matches whatever architecture the Pi is, where the precompiled `ffi` gem
  crashes on ARMv6 (Pi Zero / Pi 1) — those boards are not verified yet, but this
  is the reason the binding is written this way.
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
  examples, with `examples/lowlevel/` holding the same demos written straight
  against `Chip` / `LineRequest` and `HardwarePWM`.
- `Rgpio.available?` and `Rgpio.version` for probing the libgpiod library, and
  `Rgpio.pause` as the counterpart to Python's `signal.pause()`.
- Graceful handling of systems that ship libgpiod 1.x (e.g. Debian Bookworm,
  where it is `libgpiod.so.2`): `require "rgpio"` probes for a libgpiod v2 symbol
  and reports `Rgpio.available? == false` rather than raising, so the sysfs-only
  `HardwarePWM` and the `ioctl`-only `I2C` and `SPI` stay usable there.

[Unreleased]: https://github.com/lumbermill/rgpio/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/lumbermill/rgpio/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/lumbermill/rgpio/releases/tag/v0.1.0
