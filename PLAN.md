# rgpio — Development Plan

This document tracks **unconfirmed plans, in-progress work, and caveats** that
are not yet settled specification. Anything documented in [README.md](README.md)
is considered confirmed and supported; anything here is subject to change.

## Roadmap

| Phase | Scope | Status |
|---|---|---|
| **1** | Pi 5: GPIO I/O + hardware PWM | ✅ Done — verified on Pi 5 hardware |
| **2** | Auto-detect header gpiochip by label; Pi 4 / Pi Zero support | 🟢 Pi 4 GPIO + PWM verified (Trixie); Pi Zero **still pending** |
| **3** | High-level API (`LED`, `Button`, `PWMLED`, `Servo`, …) | ⬜ Not started (planned as a separate gem) |

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
- Pi 4 hardware PWM (Model B Rev 1.5, Bookworm — `raspi24.local`): board
  detection → `:pi4`, chip detection (`fe20c000`, `npwm == 2`), `GPIO18 →
  channel 0`, full export/frequency/duty round-trip. Verified 2026-08-27.

**Not yet validated on real hardware:**

- Pi Zero / Zero W / Zero 2 W / Pi 1 (`pinctrl-bcm2835`), including ARMv6 fiddle
  behaviour under load.

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

## Phase 3 — high-level API (future, separate gem)

A gpiozero-style convenience layer built on top of this gem:

- `LED` — on/off/toggle/blink on an output line.
- `Button` — pressed?/wait_for_press/callbacks over edge events.
- `PWMLED` — brightness via hardware or software PWM.
- `Servo` — angle/position over `HardwarePWM`.

Open questions: gem boundary (separate gem vs. `rgpio/high_level`), whether to
offer software PWM for non-PWM pins, and the callback/threading model for
`Button`.

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
- [ ] **Decide `required_ruby_version`.** The gemspec requires `>= 3.4`, but the
      stated target (Debian Trixie) ships Ruby **3.3** as its default `ruby`, so
      `gem install rgpio` would fail on a stock Trixie box. The suite and the full
      Pi 4 GPIO smoke test both pass on Ruby 3.3.8 and the code uses nothing newer
      than 3.2 syntax. Recommend lowering the floor to `>= 3.3` to match the
      target OS (pending maintainer decision).

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
