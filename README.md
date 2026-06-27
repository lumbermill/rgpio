# libgpiod-ffi

Ruby bindings for [libgpiod v2](https://git.kernel.org/pub/scm/libs/libgpiod/libgpiod.git) — the modern Linux GPIO character device API.

Provides GPIO input/output and jitter-free hardware PWM control on Raspberry Pi, targeting the `uAPI v2` ioctl interface instead of the deprecated sysfs GPIO interface. No C extension — calls `libgpiod.so` directly through the stdlib [`fiddle`](https://github.com/ruby/fiddle), which (unlike the precompiled `ffi` gem) is built with the interpreter and works on every Pi, including ARMv6 boards (Pi Zero / Pi 1).

> **Phase 1 status:** Raspberry Pi 5 only. Pi 4 / Pi Zero support is planned for Phase 2.

## Why libgpiod?

| Approach | Pi 5 works? | Notes |
|---|---|---|
| `sysfs` GPIO (`/sys/class/gpio`) | No | Deprecated since kernel 4.8 |
| Direct register access (`pigpio`, old `RPi.GPIO`) | No | RP1 chip not supported |
| `libgpiod` (GPIO character device) | **Yes** | Modern, Pi-model agnostic |

## Requirements

- **OS:** Debian Trixie (13) or later — verified target. Bookworm may work but ships libgpiod 1.x which is not supported.
- **Hardware:** Raspberry Pi 5 (Phase 1)
- **Library:** `libgpiod2` (>= 2.1)
- **Ruby:** >= 3.4 (CRuby)

Install the runtime library on the Pi:

```sh
sudo apt update
sudo apt install libgpiod3
```

To verify libgpiod is available and working:

```sh
gpiodetect          # lists GPIO chips
gpioinfo --chip gpiochip0  # lists lines on chip 0
```

## Installation

Add to your `Gemfile`:

```ruby
gem "libgpiod-ffi"
```

Or install directly:

```sh
gem install libgpiod-ffi
```

## GPIO Usage

### LED blink (output)

```ruby
require "libgpiod_ffi"

# Block form ensures the chip is closed on exit.
# With no path, the header GPIO controller is auto-detected, so the same
# code runs unchanged on Pi 5 / Pi 4 / Pi Zero (pass "/dev/gpiochipN" to
# select one explicitly).
LibgpiodFFI::Chip.open do |chip|
  puts chip.path        # "/dev/gpiochip0"
  puts chip.label       # "pinctrl-rp1" on Pi 5
  puts chip.num_lines   # 54

  request = chip.request_lines(
    offsets:   [17],         # GPIO17 = physical pin 11
    direction: :output,
    consumer:  "my-app"      # visible in gpioinfo output
  )

  5.times do
    request.set_value(17, :active)
    sleep 0.5
    request.set_value(17, :inactive)
    sleep 0.5
  end

  request.release
end
```

### Button input with edge detection

```ruby
require "libgpiod_ffi"

LibgpiodFFI::Chip.open do |chip|
  request = chip.request_lines(
    offsets:    [27],        # GPIO27 = physical pin 13
    direction:  :input,
    edge:       :both,       # detect press and release
    bias:       :pull_up,    # internal pull-up resistor
    active_low: true,        # button connects pin to GND
    consumer:   "button-reader"
  )

  puts "Waiting for button events (Ctrl-C to stop)..."
  loop do
    events = request.read_edge_events(timeout: nil)  # block indefinitely
    events.each do |event|
      state = event[:type] == :rising ? "RELEASED" : "PRESSED"
      puts "GPIO#{event[:offset]} #{state} at #{event[:timestamp_ns]} ns"
    end
  end
ensure
  request&.release
end
```

`read_edge_events` returns an array of hashes:

| Key | Type | Description |
|---|---|---|
| `:type` | `:rising` / `:falling` | Edge direction |
| `:offset` | Integer | GPIO line offset |
| `:timestamp_ns` | Integer | Kernel monotonic timestamp (nanoseconds) |

### `request_lines` options

| Option | Values | Default | Notes |
|---|---|---|---|
| `offsets:` | `Array<Integer>` | — | Required |
| `direction:` | `:input`, `:output` | — | Required |
| `edge:` | `:none`, `:rising`, `:falling`, `:both` | `:none` | Input only |
| `bias:` | `:as_is`, `:disabled`, `:pull_up`, `:pull_down` | `:as_is` | |
| `active_low:` | `true` / `false` | `false` | |
| `initial_value:` | `:active`, `:inactive` | `:inactive` | Output only |
| `consumer:` | String | `nil` | Shown in `gpioinfo` |

---

## Hardware PWM Usage

Hardware PWM is controlled through the Linux PWM sysfs interface
(`/sys/class/pwm/pwmchipN/`). No FFI required — pure file I/O.

### Step 1 — Enable the PWM overlay

Add the appropriate line to `/boot/firmware/config.txt` and **reboot**:

| GPIO pin | PWM channel | Alt function | config.txt entry |
|---|---|---|---|
| GPIO12 (pin 32) | PWM0 | Alt0 | `dtoverlay=pwm,pin=12,func=4` |
| GPIO13 (pin 33) | PWM1 | Alt0 | `dtoverlay=pwm,pin=13,func=4` |
| GPIO18 (pin 12) | PWM0 | Alt5 | `dtoverlay=pwm,pin=18,func=2` |
| GPIO19 (pin 35) | PWM1 | Alt5 | `dtoverlay=pwm,pin=19,func=2` |

> **`func` is the pin's Alt function, not the channel number:** GPIO12/13 use
> `func=4` (Alt0), but GPIO18/19 use `func=2` (Alt5). Using the wrong `func`
> loads the overlay without routing the pin to PWM — the pin stays `input` and
> nothing reaches it. Verify with `pinctrl get <n>` (expect e.g. `a0` = Alt0).

To enable two channels simultaneously (e.g. GPIO18 + GPIO19):

```
dtoverlay=pwm-2chan,pin=18,func=2,pin2=19,func2=2
```

> **Note:** The exact overlay parameters for Pi 5 depend on your kernel version.
> If the above does not work, check `/boot/firmware/overlays/README` on the Pi
> for the definitive parameter list.

**Without rebooting** (volatile, for quick testing) you can load the same
overlay at runtime — pass the parameters space-separated instead of as a CSV:

```sh
sudo dtoverlay pwm pin=12 func=4   # = dtoverlay=pwm,pin=12,func=4
sudo dtoverlay -l                  # list loaded overlays
sudo dtoverlay -r pwm              # unload
```

> **Always pass `pin` and `func` explicitly.** With no arguments
> `sudo dtoverlay pwm` defaults to `pin=18,func=2` (GPIO18), so a servo wired to
> GPIO12 gets no signal even though the program runs to completion.

### Step 2 — Verify sysfs entry

After reboot, PWM chips should appear:

```sh
ls /sys/class/pwm/
# pwmchip0  pwmchip2
```

On Pi 5 the RP1 GPIO-header PWM chip typically appears as `pwmchip2` with 4 channels (`npwm=4`), but the number can vary with kernel version. `HardwarePWM` auto-detects the correct chip.

### Step 3 — Drive a servo

```ruby
require "libgpiod_ffi"

# gpio: auto-selects chip and channel for GPIO18 on Pi 5
LibgpiodFFI::HardwarePWM.open(gpio: 18) do |pwm|
  puts "Using pwmchip#{pwm.chip_num}, channel #{pwm.channel}"

  pwm.frequency  = 50      # Hz — standard servo period (20 ms)
  pwm.duty_cycle = 0.075   # 7.5 % = 1.5 ms pulse = center position
  pwm.enable

  sleep 1

  pwm.pulse_width_us = 1000   # 1.0 ms — minimum position
  sleep 1
  pwm.pulse_width_us = 2000   # 2.0 ms — maximum position
  sleep 1
  pwm.pulse_width_us = 1500   # back to center
  sleep 1
end
# PWM is automatically disabled and unexported here
```

### GPIO-to-PWM mapping (Pi 5 / RP1)

| GPIO | Physical pin | RP1 PWM channel |
|---|---|---|
| GPIO12 | 32 | 0 |
| GPIO13 | 33 | 1 |
| GPIO18 | 12 | 2 |
| GPIO19 | 35 | 3 |

### Manual chip/channel specification

If auto-detection fails, you can specify the chip number explicitly:

```ruby
pwm = LibgpiodFFI::HardwarePWM.new(chip: 2, channel: 0)
```

List available chips:

```ruby
LibgpiodFFI::HardwarePWM.available_chips
# => [{chip: 0, npwm: 2, path: "/sys/class/pwm/pwmchip0"},
#     {chip: 2, npwm: 4, path: "/sys/class/pwm/pwmchip2"}]
```

---

## Running the examples

All examples require root (or `gpio` group membership):

```sh
# LED blink on GPIO17
sudo ruby examples/blink.rb

# Button input on GPIO27
sudo ruby examples/button.rb

# Servo sweep on GPIO18 (dtoverlay must be configured first)
sudo ruby examples/servo.rb
```

---

## API reference

### `LibgpiodFFI`

| Method | Description |
|---|---|
| `.available?` | `true` if `libgpiod.so` was found |
| `.version` | libgpiod version string (e.g. `"2.1.3"`) |

### `LibgpiodFFI::Chip`

| Method | Description |
|---|---|
| `.new(path = nil)` | Open chip; auto-detects header controller when `path` is nil |
| `.open(path = nil) { \|chip\| }` | Block form; closes on exit |
| `.list` | Array of `{path:, name:, label:, num_lines:}` for every gpiochip |
| `.detect_path` | Device path of the header GPIO controller (Pi 5 / 4 / Zero) |
| `#path` | Device path this chip was opened with |
| `#name` | Kernel name (`"gpiochip0"`) |
| `#label` | Controller label (`"pinctrl-rp1"`) |
| `#num_lines` | Number of GPIO lines |
| `#request_lines(...)` | Returns a `LineRequest` |
| `#close` | Close the chip |

### `LibgpiodFFI::LineRequest`

| Method | Description |
|---|---|
| `#get_value(offset)` | `:active` or `:inactive` |
| `#set_value(offset, value)` | Set output level |
| `#wait_edge_events(timeout:)` | `true` if event ready |
| `#read_edge_events(timeout:, capacity:)` | Array of event hashes |
| `#release` | Release kernel request |

### `LibgpiodFFI::HardwarePWM`

| Method | Description |
|---|---|
| `.new(gpio:)` | Auto-detect chip/channel for GPIO pin |
| `.new(chip:, channel:)` | Explicit chip/channel |
| `.open(...) { \|pwm\| }` | Block form; closes on exit |
| `.available_chips` | List sysfs PWM chips |
| `#frequency=` / `#frequency` | Hz |
| `#duty_cycle=` / `#duty_ratio` | 0.0–1.0 ratio |
| `#pulse_width_us=` / `#pulse_width_us` | Microseconds |
| `#enable` / `#disable` | Start/stop PWM output |
| `#close` | Disable and unexport |

---

## Architecture

```
┌─────────────────────────────────────────┐
│  High-level API (Phase 3, future gem)   │  LED, Button, Servo classes
├─────────────────────────────────────────┤
│  LibgpiodFFI::Chip / LineRequest        │  OOP wrappers (this gem)
├──────────────────┬──────────────────────┤
│  Native (fiddle) │  HardwarePWM         │  libgpiod.so  /  sysfs PWM
└──────────────────┴──────────────────────┘
       libgpiod v2 ABI          Linux PWM sysfs
```

- **Layer 1 (`Native`)** — raw `fiddle` declarations of the libgpiod C functions
- **Layer 2 (`Chip`, `LineRequest`, `HardwarePWM`)** — Ruby-idiomatic wrappers
- **Layer 3 (Phase 3)** — high-level gpiozero-style API (planned as a separate gem)

---

## Roadmap

| Phase | Scope |
|---|---|
| **1** | Pi 5, GPIO I/O + hardware PWM ✅ |
| **2 (current)** | Auto-detect gpiochip by label ✅; Pi 4 / Pi Zero hardware validation (pending hardware) |
| **3** | High-level API: `LED`, `Button`, `PWMLED`, … (separate gem) |

---

## License

[MIT](LICENSE)
