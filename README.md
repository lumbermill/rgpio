# rgpio

GPIO, PWM, I2C and SPI on Raspberry Pi from Ruby, through the kernel's own
interfaces rather than direct register access:

- **GPIO** — [libgpiod v2](https://git.kernel.org/pub/scm/libs/libgpiod/libgpiod.git),
  the Linux GPIO character device (`uAPI v2`), instead of the deprecated sysfs
  GPIO interface. Works on the Pi 5's RP1 as on older boards.
- **PWM** — either the hardware PWM peripheral through the kernel's PWM
  subsystem (`/sys/class/pwm`), jitter-free but needing a `dtoverlay`, or
  software PWM timed in Ruby on any line, with no configuration at all.
- **I2C and SPI** — `ioctl` calls on `/dev/i2c-N` and `/dev/spidev*`; no
  libgpiod involved.

On top sits a gpiozero-style device layer (`LED`, `Button`, `Servo`, ...).

No C extension — libgpiod is called through the stdlib
[`fiddle`](https://github.com/ruby/fiddle), which (unlike the precompiled `ffi`
gem) is built with the interpreter and works on every Pi, including ARMv6 boards
(Pi Zero / Pi 1). Line values are read and written with `IO#ioctl` on the
request's descriptor, which on a Pi Zero is eight times faster than libgpiod's
value functions through fiddle.

> **Status:** GPIO + hardware PWM verified on Raspberry Pi 5 and Raspberry Pi 4
> (Trixie, libgpiod 2.x); GPIO, hardware PWM, I2C and SPI also verified on a
> Pi Zero W (ARMv6). The device API (`LED` / `Button` / `Motor`) is verified on Pi 5.
> Hardware PWM (sysfs) also works on a Bookworm Pi 4, where the libgpiod GPIO
> path is unavailable (v1). Multi-board support, the roadmap, and planned APIs
> are tracked in [PLAN.md](PLAN.md); released changes are recorded in
> [CHANGELOG.md](CHANGELOG.md).

```ruby
require "rgpio"

led = Rgpio::LED.new(4)              # GPIO4 = physical pin 7
button = Rgpio::Button.new(17)       # switch between GPIO17 and 3.3 V

button.when_pressed  { led.on }
button.when_released { led.off }

Rgpio.pause                          # run the callbacks until Ctrl-C
```

## Requirements

- **OS:** Debian Trixie (13) or later — verified target. Bookworm ships libgpiod 1.x, which is not supported.
- **Hardware:** Raspberry Pi 5 and Pi 4 (verified); Pi Zero W for GPIO, hardware PWM, I2C and SPI (verified). Other Pi models and device classes on the Zero: see [PLAN.md](PLAN.md).
- **Library:** libgpiod >= 2.1 (Debian package `libgpiod3`)
- **Ruby:** >= 3.3 (CRuby) — matches Trixie's default `ruby`

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
gem "rgpio"
```

Or install directly:

```sh
gem install rgpio
```

## Hello, world

Wire an LED with a 330 Ω resistor between GPIO4 (pin 7) and GND (pin 6), save
this as `blink.rb` and run `ruby blink.rb`:

```ruby
require "rgpio"

led = Rgpio::LED.new(4)

5.times do
  led.on
  sleep 0.5
  led.off
  sleep 0.5
end

led.close
```

If it fails with `Errno::EACCES`, add yourself to the `gpio` group
(`sudo usermod -aG gpio $USER`, then log in again).

## What's in the box

| Area | Classes | Guide |
|---|---|---|
| Digital devices (gpiozero-style) | `LED`, `Button`, `RotaryEncoder`, `Motor` | [Device API](docs/guide.md#device-api) |
| PWM devices | `PWMLED`, `RGBLED`, `Servo` | [Device API](docs/guide.md#device-api), [Software PWM](docs/guide.md#software-pwm) |
| Raw GPIO | `Chip`, `LineRequest` | [GPIO Usage](docs/guide.md#gpio-usage) |
| Hardware PWM | `HardwarePWM` | [Hardware PWM Usage](docs/guide.md#hardware-pwm-usage) |
| I2C | `I2C`, `ADT7410`, `ST7032` | [I2C Usage](docs/guide.md#i2c-usage) |
| SPI | `SPI`, `MCP3208`, `ILI9341` (colour TFT), `XPT2046` (touch) | [SPI Usage](docs/guide.md#spi-usage) |

Every class is documented in full in **[docs/guide.md](docs/guide.md)**, with
wiring notes, the [API reference](docs/guide.md#api-reference) and
[how to run the examples](docs/guide.md#running-the-examples) in
[`examples/`](examples). Devices written but still waiting on hardware
verification (such as `MotionSensor`) are listed in [PLAN.md](PLAN.md).

The PWM devices choose their channel from the pin. GPIO12/13/18/19 use the
hardware PWM peripheral once a `dtoverlay` line in `config.txt` routes the pin
to it; every other line, and those four without the overlay, use software PWM,
which needs no configuration. The
[Hardware PWM guide](docs/guide.md#hardware-pwm-usage) has the overlay line for
each pin, and [Choosing the channel](docs/guide.md#choosing-the-channel) how
the choice is made.

## Project status

The current release is `0.1.1`. It is `0.x` in earnest: everything documented
has been exercised on real hardware, but the API may still change before `1.0`.

- **Released changes:** [CHANGELOG.md](CHANGELOG.md)
- **Roadmap, planned APIs, and multi-board validation status:** [PLAN.md](PLAN.md)

## License

[MIT](LICENSE)
