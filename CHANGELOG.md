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

### Changed

- `require "rgpio"` no longer crashes on systems that ship libgpiod 1.x (e.g.
  Debian Bookworm, where it is `libgpiod.so.2`): the loader now probes for a
  libgpiod v2 symbol and reports `Rgpio.available? == false` instead of raising
  when only v1 is present. The sysfs-only `HardwarePWM` stays usable there.
- `Rgpio.available?` / `.version` helpers for probing the libgpiod library.
- Examples: `examples/blink.rb`, `examples/button.rb`, `examples/servo.rb`.
- Minitest suite covering chip-selection logic and PWM helpers.

[Unreleased]: https://github.com/lumbermill/rgpio/commits/main
