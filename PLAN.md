# rgpio — Development Plan

This document tracks **unconfirmed plans, in-progress work, and caveats** that
are not yet settled specification. Anything documented in [README.md](README.md)
is considered confirmed and supported; anything here is subject to change.

## Roadmap

| Phase | Scope | Status |
|---|---|---|
| **1** | Pi 5: GPIO I/O + hardware PWM | ✅ Done — verified on Pi 5 hardware |
| **2** | Auto-detect header gpiochip by label; Pi 4 / Pi Zero support | 🟡 Code done; Pi 4 / Zero **hardware validation pending** |
| **3** | High-level API (`LED`, `Button`, `PWMLED`, `Servo`, …) | ⬜ Not started (planned as a separate gem) |

## Multi-board support — validation status

The chip auto-detection selects the 40-pin header controller by SoC label
(`pinctrl-rp1` → Pi 5, `pinctrl-bcm2711` → Pi 4/400, `pinctrl-bcm2835` →
Pi Zero / 1 / 2 / 3). The selection logic is unit-tested and works on Pi 5.

**Not yet validated on real hardware:**

- Pi 4 / Pi 400 (`pinctrl-bcm2711`) GPIO I/O and edge events.
- Pi Zero / Zero W / Zero 2 W / Pi 1 (`pinctrl-bcm2835`), including ARMv6 fiddle
  behaviour under load.
- Hardware PWM on any board other than Pi 5. `HardwarePWM` currently maps
  `gpio:` → channel using a **Pi 5 (RP1) table only**
  (`GPIO_TO_PWM_CHANNEL_PI5`); `.new(gpio:)` raises on other boards. Pi 4 PWM
  chip/channel mapping is not yet implemented.

Until validated, treat boards other than Pi 5 as best-effort.

## Planned API additions (current gem)

These extend the existing `Rgpio::*` classes and are candidates before `0.1.0`
is published:

- **Pi 4 hardware-PWM mapping** — extend the `gpio:` → chip/channel lookup
  beyond the RP1 table so `HardwarePWM.open(gpio:)` works on Pi 4.

### Done

- ~~**Batch multi-line I/O**~~ — `LineRequest#get_values` / `#set_values` via
  `gpiod_line_request_get_values_subset` / `set_values_subset`. Verified on Pi 5
  hardware (atomic reads/writes and subset addressing). Now confirmed spec — see
  README.

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

## Environment caveats (not yet pinned as spec)

- **PWM overlay parameters vary by kernel version.** The `dtoverlay` `pin`/`func`
  values in the README are correct for current Trixie kernels; if they change,
  the definitive list is in `/boot/firmware/overlays/README` on the Pi.
- **PWM sysfs chip number varies by kernel version.** On Pi 5 the RP1 header PWM
  is typically `pwmchip2`, but this is auto-detected rather than assumed.
