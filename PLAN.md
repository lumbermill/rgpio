# rgpio — Development Plan

This document tracks **unconfirmed plans, in-progress work, and caveats** that
are not yet settled specification. Anything documented in [README.md](README.md)
is considered confirmed and supported; anything here is subject to change.

## Roadmap

| Phase | Scope | Status |
|---|---|---|
| **1** | Pi 5: GPIO I/O + hardware PWM | ✅ Done — verified on Pi 5 hardware |
| **2** | Auto-detect header gpiochip by label; Pi 4 / Pi Zero support | 🟢 Pi 4 GPIO + PWM verified (Trixie); Pi Zero **still pending** |
| **3** | High-level API (`LED`, `Button`, `PWMLED`, `Servo`, …) | 🟢 3a verified on Pi 5 (`MotionSensor` deferred); 3b–3e pending |

## Multi-board support — validation status

The chip auto-detection selects the 40-pin header controller by SoC label
(`pinctrl-rp1` → Pi 5, `pinctrl-bcm2711` → Pi 4/400, `pinctrl-bcm2835` →
Pi Zero / 1 / 2 / 3). The selection logic is unit-tested and works on Pi 5.

**Validated on real hardware:**

- Pi 4 GPIO via libgpiod (Model B Rev 1.2, Trixie, libgpiod 2.2.1, Ruby 3.3.8 —
  `raspi26.local`): header auto-detect → `gpiochip0 [pinctrl-bcm2711]` (58 lines),
  single + batch `get_value(s)` / `set_value(s)` (bias reads and output
  round-trip), and the edge-event API. Full suite (47) green on 3.3.8.
  Verified 2026-09-05.
- Pi 5 device API (`LED` / `Button` / `Motor`, Trixie): LED blink on GPIO4,
  `Button` press/release with the default pull-down bias and 5 ms debounce, and
  `Motor` forward/backward through a DRV8835 on GPIO2/GPIO14. `active_low: true`
  on `Button` inverts the callbacks too, settling the edge-polarity question:
  the kernel does report edges in logical terms, as `InputDevice` assumed.
  Verified 2026-09-18.
- Pi 4 hardware PWM (Model B Rev 1.5, Bookworm — `raspi24.local`): board
  detection → `:pi4`, chip detection (`fe20c000`, `npwm == 2`), `GPIO18 →
  channel 0`, full export/frequency/duty round-trip. Verified 2026-08-27.

**Not yet validated on real hardware:**

- Pi Zero / Zero W / Zero 2 W / Pi 1 (`pinctrl-bcm2835`), including ARMv6 fiddle
  behaviour under load.
- `MotionSensor` — deferred, see Phase 3 below.

Until validated, treat GPIO (libgpiod) on Pi Zero / Pi 1 as best-effort.

## Planned API additions (current gem)

These extend the existing `Rgpio::*` classes and are candidates before `0.1.0`
is published:

- _(none pending — see Done below)_

### Done

- ~~**Pi 4 hardware-PWM mapping**~~ — board-aware `HardwarePWM`: `detect_board`
  reads `/proc/device-tree/model`; `.new(gpio:, board:)` selects the channel per
  board (Pi 4: `GPIO12/18 → 0`, `GPIO13/19 → 1`; chip at `fe20c000`, `npwm == 2`).
  Verified on a real Pi 4 (2026-08-27). Now confirmed spec — see README.
- ~~**Batch multi-line I/O**~~ — `LineRequest#get_values` / `#set_values` via
  `gpiod_line_request_get_values_subset` / `set_values_subset`. Verified on Pi 5
  hardware (atomic reads/writes and subset addressing). Now confirmed spec — see
  README.
- ~~**Graceful libgpiod v1 handling**~~ — `require "rgpio"` used to crash when
  only libgpiod 1.x was present (e.g. Bookworm's `libgpiod.so.2`). The loader now
  probes for a v2 symbol and reports `Rgpio.available? == false` instead. Found
  and fixed while validating PWM on the Bookworm Pi 4.

## Phase 3 — high-level API

A gpiozero-style convenience layer on top of the low-level classes. The goal is
concrete: port every `gpiozero` / `RPi.GPIO` sample in 実践課題3 of
*Dive into Raspberry Pi 2026* (<https://lmlab.net/books/2601_raspi/>) to Ruby,
ship each one as an `examples/` script, and verify it on real hardware. The
examples are named after what they demonstrate rather than after the book's
Python filenames, so they stand on their own for anyone reading the gem.

**Settled decisions**

- **One gem, not two.** The device layer lives in `lib/rgpio/devices/` but keeps
  the `Rgpio::` namespace, so `require "rgpio"` is all a reader needs. It adds
  no dependencies, so bundling costs nothing, and splitting later is a directory
  move. A separate gem would buy independent release cycles — worth little for a
  single maintainer — at the cost of version-range bookkeeping and a two-gem
  install for the book's readers.
- **Hardware PWM over software PWM.** The book drives the servo on GPIO4 and the
  RGB LED on GPIO2/3/4, none of which are PWM pins, so gpiozero falls back to
  software PWM — and the book itself notes the resulting servo jitter. The book
  will be revised to use the hardware PWM pins (GPIO12/13/18/19) instead, which
  removes the jitter and avoids implementing software PWM at all. Ruby threads
  would jitter at least as much as gpiozero does.
- **Callbacks over blocks, dispatched from one watcher thread per device.**
  `button.when_pressed { ... }` rather than gpiozero's attribute assignment.
  The thread blocks in `read_edge_events` with a finite timeout so `#close` can
  stop it; fiddle releases the GVL during the call, so the main thread stays
  responsive. `Rgpio.pause` stands in for Python's `signal.pause()`.

**Staging**

| Stage | Scope | Book sections | Status |
|---|---|---|---|
| 3a | `LED` / `Button` / `Motor` / `Rgpio.pause` | LED点滅, スイッチ, モータードライバ | ✅ verified on Pi 5 — confirmed spec, see README |
| 3a′ | `MotionSensor` | モーションセンサ | ⏸ written + unit-tested, hardware verification deferred |
| 3b | `Rgpio::I2C` + ADT7410 / ST7032 examples | 温度センサ, LCD | ⬜ |
| 3c | `Servo` / `PWMLED` / `RGBLED` over `HardwarePWM` | サーボ, フルカラーLED | ⬜ |
| 3d | `Rgpio::SPI` + `MCP3208` | ADコンバータ | ⬜ |
| 3e | Camera examples shelling out to `rpicam-still` | モーション+撮影, 測距センサ | ⬜ |

I2C and SPI need no libgpiod: they are `ioctl` calls on `/dev/i2c-N` and
`/dev/spidevN.M`, so they stay dependency-free like the sysfs PWM code.

**Open questions**

- The book's switch is wired to 3.3 V, so `Button` defaults to a pull-**down**
  bias, unlike gpiozero's pull-up default. That wiring is confirmed on hardware;
  what is left is to cross-check the book's circuit diagram before it is revised.
- `wait_for_press` / `LED#blink` are deliberately not implemented yet — no book
  sample needs them.
- `Motor` has no speed control (it would need PWM on both lines); the book's
  sample only uses full-speed forward/backward.
- `MotionSensor` is **deferred**: the PIR modules on hand are an unreliable
  supply, so it is out of the 3a verification scope and stays out of the README
  until a module can be tested end to end. The class, its unit tests and
  `examples/motion_sensor.rb` ship as they are. What testing did show:
  it reports every pulse the module emits, and the D-SUN (BISS0001)
  board used for verification false-triggers on 5 V rail noise often enough to
  be noticeable — 0.9 s pulses arriving with nothing moving. gpiozero smooths
  this with `queue_len`: a thread polls at `sample_rate` and `is_active`
  compares the windowed average against `threshold`, so isolated pulses fall
  below the bar. Porting that directly would replace the kernel edge watcher
  with a 10 Hz poll, a poor trade for a gem built on the character-device
  interface; the edge-driven equivalent is to re-read `value` a fixed delay
  after a rising edge and dispatch only if the line is still active.
  `debounce_us` cannot stand in for either: a spurious pulse is stable for its
  whole length, so any debounce long enough to drop it also drops real
  detections. Not implemented — decoupling the sensor (100 µF + 0.1 µF across
  VCC/GND) is the first fix, and no book sample needs the filtering.

## Release / tooling readiness

- [ ] Publish `0.1.0` to RubyGems (currently unpublished; `mfa_required` is set).
      Gem metadata (`source_code_uri` / `changelog_uri` / `bug_tracker_uri`) and
      packaged files (incl. CHANGELOG.md) are ready.
- [x] GitHub Actions CI running the logic-only test suite (no hardware needed) —
      `.github/workflows/ci.yml`, Ruby 3.4, bundler-less (the committed lock is
      pinned to the aarch64 dev box). A `RuboCop` lint job runs alongside.
- [x] RuboCop lint configuration — `.rubocop.yml` tuned to the project's style;
      the tree is clean. `rake` runs test + rubocop.
- [ ] Integration tests for `LineRequest` / edge events (needs GPIO loopback
      wiring; not runnable in CI). A manual Pi 5 smoke test already verified
      batch `get_values`/`set_values`.
- [ ] Optional: RuboCop extensions (`rubocop-minitest`, `rubocop-rake`).
- [x] `required_ruby_version` lowered to `>= 3.3` to match Trixie's default
      `ruby` (so `gem install rgpio` works on a stock Trixie box). Verified on
      Ruby 3.3.8; CI now tests 3.3 and 3.4.

## Environment caveats (not yet pinned as spec)

- **PWM overlay parameters vary by kernel version.** The `dtoverlay` `pin`/`func`
  values in the README are correct for current Trixie kernels; if they change,
  the definitive list is in `/boot/firmware/overlays/README` on the Pi.
- **PWM sysfs chip number varies by kernel version.** On Pi 5 the RP1 header PWM
  is typically `pwmchip2`, but this is auto-detected rather than assumed. (On the
  current dev Pi 5 it is actually `pwmchip0`.)
- **Without the header PWM overlay, auto-detection can select the RP1 fan PWM.**
  When the header PWM0 (`1f00098000`) is not enabled via dtoverlay, the only PWM
  chip present may be the RP1 fan controller PWM1 (`1f0009c000`), which also
  reports `npwm == 4`. `detect_pwm_chip!` prefers the header address first, but
  falls back to `npwm == 4` and would then pick the fan chip. Enable the header
  PWM overlay before using `HardwarePWM(gpio:)`, or pass `chip:` explicitly.
