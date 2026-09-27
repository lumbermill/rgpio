# rgpio — Development Plan

This document tracks **unconfirmed plans, in-progress work, and caveats** that
are not yet settled specification. Anything documented in [README.md](README.md)
is considered confirmed and supported; anything here is subject to change.

## Roadmap

| Phase | Scope | Status |
|---|---|---|
| **1** | Pi 5: GPIO I/O + hardware PWM | ✅ Done — verified on Pi 5 hardware |
| **2** | Auto-detect header gpiochip by label; Pi 4 / Pi Zero support | 🟢 Pi 4 GPIO + PWM verified (Trixie); Pi Zero **still pending** |
| **3** | High-level API (`LED`, `Button`, `PWMLED`, `Servo`, …) | 🟢 3a + 3b verified on Pi 5 (`MotionSensor` deferred); 3c–3e pending |

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
- Pi 5 I2C bus layer (`Rgpio::I2C`, Trixie): read the 128-byte EDID of the
  HDMI DDC EEPROM (`/dev/i2c-13`, address 0x50) with a valid checksum, both as
  separate write + read and as a `write_read` repeated-START transfer, with the
  two agreeing byte for byte. A bus with nothing at the address reports
  `Errno::EREMOTEIO` rather than hanging. This exercises the `i2c_msg` /
  `i2c_rdwr_ioctl_data` packing, which is where a mistake would corrupt
  transfers silently. Verified 2026-09-23.
- Pi 5 I2C devices (`ADT7410` + `ST7032`, Trixie, header bus `/dev/i2c-1`): both
  modules on one bus (0x48 and 0x3e, one `I2C` object each) with no contention.
  ADT7410: ID register 0xcb, room temperature in 0.0625 degC steps in 13-bit
  mode, 0.0078 degC steps in 16-bit mode, and switching resolution at runtime.
  ST7032 on an AQM0802 (8x2): both rows legible at the 3.3 V defaults
  (`contrast: 0x20`, booster on) with no adjustment needed, `move_to` addressing
  each row, and in-place overwrite. Verified 2026-09-27.
- Pi 5 software PWM accuracy (`Rgpio::SoftwarePWM`, Trixie): measured with a
  jumper from GPIO23 to GPIO24 and the kernel's own edge timestamps
  (`examples/pwm_jitter.rb`; the generator runs in a forked process so it does
  not share a GVL with the measuring loop). At 50 Hz / 1500 us — a servo's centre
  position — the pulse came out at 1504.9 us mean, **6.2 us standard deviation**,
  4.7 us median error, 27 us p99, over three runs that agreed to within 0.5 us of
  mean. At 100 Hz / duty 0.5 the pulse held 5007.7 us with 4.9 us sd. No dropped
  cycles in any run. CPU cost of the generating thread: 2.7% of one core at
  50 Hz, 5.3% at 100 Hz, 4.3% at 1 kHz (the spin cap keeps the high frequency
  cheap). Verified 2026-09-27.
- Pi 5 gpiozero comparison, same wiring and same measurement: gpiozero's
  `PWMOutputDevice` at 50 Hz / duty 0.075 produced a **1424 us** pulse (82 us
  median error) and quantises duty to whole percent — 0.070, 0.075 and 0.079 all
  came out at ~1410-1424 us and 0.080 jumped to 1621 us, i.e. **200 us steps** on
  a 20 ms frame. Its cause is in gpiozero, not lgpio: the lgpio pin driver passes
  `int(value * 100)`. A 180-degree servo therefore has about ten reachable
  positions under Python on a Pi 5, against continuous positioning here. At
  100 Hz / duty 0.5 (where 50% is exactly representable) the two are equivalent
  (2.5 us vs 2.9 us median error). Verified 2026-09-27.
- Pi 4 hardware PWM (Model B Rev 1.5, Bookworm — `raspi24.local`): board
  detection → `:pi4`, chip detection (`fe20c000`, `npwm == 2`), `GPIO18 →
  channel 0`, full export/frequency/duty round-trip. Verified 2026-08-27.

**Not yet validated on real hardware:**

- Pi Zero / Zero W / Zero 2 W / Pi 1 (`pinctrl-bcm2835`), including ARMv6 fiddle
  behaviour under load. The `i2c_msg` struct layout is 32-bit-aware (the buffer
  pointer sits at offset 8 either way) but has only been exercised on aarch64.
- `Rgpio::ST7032` on a 16-column AQM1602, and on a 5 V module (`booster: false`);
  only the 8x2 AQM0802 at 3.3 V has been on the bus.
- `Rgpio::ADT7410` below 0 degC — the negative branch of the conversion is
  unit-tested against the datasheet's codes but has never come off real silicon.
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
- **Software PWM by default, hardware PWM opt-in** (revised 2026-09-27; this
  reverses the earlier "hardware PWM only" decision). The constraint that
  settled it: *the book's readers must not have to edit config.txt*, and hardware
  PWM cannot be reached without a dtoverlay — on a Pi 5 the stock overlays route
  at most **two** header pins (`pwm-2chan`: `pin` from 12/18, `pin2` from 13/19),
  so an `RGBLED` could not work at all. `Rgpio::SoftwarePWM` needs no
  configuration, drives any line, and — measured, see below — beats gpiozero on
  its own ground, so the book keeps its GPIO2/3/4 wiring and no revision is
  needed. `pwm: :hardware` stays available for anyone who can set the overlay.
  What gpiozero does, for the record: everything goes through `lgpio.tx_pwm`,
  which its own docs call "software timed PWM" — it never touches the kernel PWM
  interface, which is why it needs no config.txt either.
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
| 3b | `Rgpio::I2C` + ADT7410 / ST7032 examples | 温度センサ, LCD | ✅ verified on Pi 5 — confirmed spec, see README |
| 3c | `Servo` / `PWMLED` / `RGBLED` over `SoftwarePWM` (hardware opt-in) | サーボ, フルカラーLED | 🟡 `SoftwarePWM` done + measured on Pi 5; device classes next |
| 3d | `Rgpio::SPI` + `MCP3208` | ADコンバータ | ⬜ |
| 3e | Camera examples shelling out to `rpicam-still` | モーション+撮影, 測距センサ | ⬜ |

I2C and SPI need no libgpiod: they are `ioctl` calls on `/dev/i2c-N` and
`/dev/spidevN.M`, so they stay dependency-free like the sysfs PWM code.

**Phase 3b notes**

- `Rgpio::I2C` is one object per address: `I2C.new(address:, bus: 1)` claims the
  address with the `I2C_SLAVE` ioctl and keeps the file open. Two devices on one
  bus (the sensor at 0x48 and the display at 0x3e) are therefore two `I2C`
  objects, not a shared one — that is what the kernel interface models, and it
  keeps `write`/`read` free of an address argument.
- `write_read` issues a repeated START through `I2C_RDWR` rather than a write
  followed by a separate read. Both work for the ADT7410, but only the former is
  safe if another master shares the bus.
- No SMBus (`I2C_SMBUS`) layer: the ioctl only reaches adapters that implement
  the SMBus subset, and plain I2C transfers cover every device in the book.
- No bus scan (`i2cdetect`-style) yet. A scan has to guess between a quick-write
  and a read probe per address, and probing write-only devices can change their
  state; `i2cdetect -y 1` already does it safely from the shell.
- Redrawing with `clear` once a second visibly flickers on these panels, because
  the clear blanks the row for as long as the next transfer takes. The examples
  write the label once and then overwrite the value in place, padded to the row
  width. Found while verifying on the AQM0802.
- `ST7032#print` drops text that would run past the last column instead of
  wrapping, because the controller's DDRAM addresses are not contiguous between
  rows — an overrun scatters characters into invisible addresses rather than
  continuing on the next line.
- Contrast is the one setting that cannot be read back, and a wrong value looks
  exactly like a dead panel. 0x20 with the booster on is the 3.3 V default; the
  5 V panels want roughly 0x28 with the booster off.

**Phase 3c notes**

- `SoftwarePWM` sleeps until shortly before each edge and then spins. The spin is
  what makes it usable: with `spin_us: 0`, a 50 Hz 1500 us pulse spread over
  72..6756 us (386 us sd) — a servo would visibly slam around. 300 us of spin
  brought that to 6 us sd; 1000 us was no better. The spin is capped at 5% of the
  period per edge so a high frequency cannot turn the thread into a busy loop.
- Two accuracy bugs, both found by measuring and both worth remembering:
  re-reading the frequency/duty under the mutex *between* the deadline and the
  rising edge charged that work to the pulse, and timing the high phase from the
  nominal deadline charged it the wake-up overshoot too (15 us of every pulse).
  The high phase is now timed from a clock read taken just before the rising
  edge's `set_value`, and a **write of the level the line already holds** goes
  out before that read: the first call after waking from the long low phase is
  slow and erratic, and paying it in advance leaves the real edge on a warm path.
  That one line took the spread from 20 us to 6 us.
- Remaining bias is +5 us (pulse slightly long), stable run to run. On a
  180-degree servo that is 0.4 degrees, and a constant offset is what the
  per-servo `min_pulse_us` / `max_pulse_us` calibration absorbs anyway.
- Spread depends on what else the machine is doing: the same configuration
  measured 6 us sd on an idle box and 30 us sd with an editor indexing in the
  background. Ruby cannot do better — while the main thread holds the GVL, the
  generating thread cannot wake. Python has the same limitation with the GIL.
- `RGBLED` will run three `SoftwarePWM` channels, so three generating threads
  that each spin. One thread multiplexing three lines with batch `set_values`
  would be cheaper and is the obvious optimisation if it proves necessary; for
  LEDs the edge placement is invisible, so it has not been.

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
