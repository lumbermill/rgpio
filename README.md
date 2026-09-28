# rgpio

Ruby bindings for [libgpiod v2](https://git.kernel.org/pub/scm/libs/libgpiod/libgpiod.git) — the modern Linux GPIO character device API.

Provides GPIO input/output and jitter-free hardware PWM control on Raspberry Pi, targeting the `uAPI v2` ioctl interface instead of the deprecated sysfs GPIO interface. No C extension — calls `libgpiod.so` directly through the stdlib [`fiddle`](https://github.com/ruby/fiddle), which (unlike the precompiled `ffi` gem) is built with the interpreter and works on every Pi, including ARMv6 boards (Pi Zero / Pi 1).

> **Status:** GPIO + hardware PWM verified on Raspberry Pi 5 and Raspberry Pi 4
> (Trixie, libgpiod 2.x). The device API (`LED` / `Button` / `Motor`) is verified
> on Pi 5. Hardware PWM (sysfs) also works on a Bookworm Pi 4, where the libgpiod
> GPIO path is unavailable (v1). Multi-board support, the roadmap, and planned
> APIs are tracked in [PLAN.md](PLAN.md); released changes are recorded in
> [CHANGELOG.md](CHANGELOG.md).

## Why libgpiod?

| Approach | Pi 5 works? | Notes |
|---|---|---|
| `sysfs` GPIO (`/sys/class/gpio`) | No | Deprecated since kernel 4.8 |
| Direct register access (`pigpio`, old `RPi.GPIO`) | No | RP1 chip not supported |
| `libgpiod` (GPIO character device) | **Yes** | Modern, Pi-model agnostic |

## Requirements

- **OS:** Debian Trixie (13) or later — verified target. Bookworm ships libgpiod 1.x, which is not supported.
- **Hardware:** Raspberry Pi 5 and Pi 4 (verified). Other Pi models: see [PLAN.md](PLAN.md).
- **Library:** `libgpiod2` (>= 2.1)
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

## Device API

`LED`, `Button`, `Motor`, `PWMLED`, `RGBLED` and `Servo` wrap `Chip` /
`LineRequest` in one object per piece of hardware, in the style of Python's
gpiozero. A device opens its own chip
unless you hand it one with `chip:`, and `#close` releases only what it owns.
Devices still under hardware validation are listed in [PLAN.md](PLAN.md).

### LED

```ruby
require "rgpio"

led = Rgpio::LED.new(4)      # GPIO4 = physical pin 7

5.times do
  led.on
  sleep 1
  led.off
  sleep 1
end

led.close                    # releases the line and the chip
```

`LED` is an `OutputDevice`, which also offers `#toggle`, `#value` / `#value=`
and `#on?`. Pass `active_low: true` when the LED is wired to sink current
(`#on` then drives the line low), and `initial_value: true` to have it lit the
moment the line is claimed.

### Button

```ruby
require "rgpio"

button = Rgpio::Button.new(4)

button.when_pressed  { puts "Pressed" }
button.when_released { puts "Released" }

Rgpio.pause                  # block until Ctrl-C while callbacks run
button.close
```

Callbacks run on a watcher thread that waits on kernel edge events, one thread
per device, started by the first callback and stopped by `#close`. A callback
that raises is reported on `$stderr` without taking the watcher down.
`Rgpio.pause` is the counterpart of Python's `signal.pause()`.

The default bias is pull-**down**, for a switch wired between the GPIO line and
3.3 V; pass `pull_up: true` for one wired to GND. Presses are debounced in the
kernel for 5 ms (`debounce_us:` to change it), so one press fires one callback.

`active_low: true` inverts the logic, and the callbacks follow it: the kernel
reports edges in logical terms, so `when_pressed` fires when the line goes
*low*.

### Motor

```ruby
require "rgpio"

motor = Rgpio::Motor.new(forward: 2, backward: 14)

motor.forward
sleep 5
motor.backward
sleep 5
motor.stop

motor.close
```

Written for a two-input driver such as the DRV8835 or SN754410 in IN/IN mode:
one line drives the motor forward, the other backward, and `Motor` drops one
before raising the other so the driver is never asked to source and sink the
same output at once. Wire the motor across the driver's two outputs
(`AOUT1`/`AOUT2`) — with one terminal on GND only one direction works. Speed
control would need PWM on both lines and is not implemented.

### PWMLED

`LED` is on or off; `PWMLED` has a level in between, from a PWM channel.

```ruby
led = Rgpio::PWMLED.new(4)
led.value = 0.25            # a quarter bright (#brightness is an alias)
led.on                      # 1.0
led.toggle                  # inverts the level: 0.25 becomes 0.75
led.close
```

The level holds with no further calls — one assignment, and the channel keeps
generating. Any line works: the default channel is {Rgpio::SoftwarePWM}, which
needs no dtoverlay. See [Software PWM](#software-pwm) for `pwm: :hardware`.

### RGBLED

Three PWM channels as one object, one per colour.

```ruby
led = Rgpio::RGBLED.new(red: 17, green: 27, blue: 22)
led.color = :magenta        # or any name in Rgpio::RGBLED::COLORS
led.color = [1.0, 0.4, 0.0] # or a triple, 0.0..1.0 each
led.blue = 0.5              # or one channel at a time
led.off
led.close
```

The default wiring is common cathode: each line drives its colour through its own
resistor and the common leg goes to GND. For a common-anode part, tie the common
leg to 3.3 V and pass `active_low: true`.

White comes out tinted unless the channels are scaled to match, because the three
dies are not equally bright for equal duty:

```ruby
led = Rgpio::RGBLED.new(red: 17, green: 27, blue: 22, balance: [1.0, 0.8, 0.8])
```

`balance:` scales every level asked for, so named colours come out right too, and
`#color` keeps reporting what was asked for. The right value belongs to the part,
not to the gem — `ruby examples/rgb_balance.rb` steps through candidates with the
LED showing white so you can pick one by eye.

### Servo

```ruby
servo = Rgpio::Servo.new(4)
servo.max                   # one end of the travel
servo.mid                   # centre
servo.angle = 45            # or by angle, -90..90 by default
servo.detach                # stop the pulses: the horn goes limp
servo.close
```

A servo holds its position only while pulses keep arriving, so `#detach` stops
sending them: the horn can then be turned by hand, and the servo stops drawing
the current — and making the heat — of holding against a load. It has no grip on
anything while detached. Setting `#value` or `#angle` again resumes;
`#attached?` reports which it is.

Pulse widths vary by servo. The default 1000..2000 us is the range every hobby
servo understands, and many reach further:

```ruby
servo = Rgpio::Servo.new(4, min_pulse_us: 500, max_pulse_us: 2500,
                            min_angle: 0, max_angle: 180)
servo.pulse_width_us = 2300 # drive a width directly, to find the real travel
```

A servo driven past its travel buzzes and heats up, so widen the range only as
far as the part allows, and by measuring rather than by trusting.

### Sharing one chip

```ruby
chip  = Rgpio::Chip.new
red   = Rgpio::LED.new(17, chip: chip)
green = Rgpio::LED.new(27, chip: chip)

red.on
green.off

[red, green].each(&:close)   # the chip stays open — the devices did not open it
chip.close
```

---

## GPIO Usage

The classes the device API is built on. Use them when you need control the
device classes do not expose — batch I/O across lines, raw edge-event
timestamps, or a specific `/dev/gpiochipN`.

### LED blink (output)

```ruby
require "rgpio"

# Block form ensures the chip is closed on exit.
# With no path, the 40-pin header GPIO controller is auto-detected by label
# (pass "/dev/gpiochipN" to select one explicitly).
Rgpio::Chip.open do |chip|
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
require "rgpio"

Rgpio::Chip.open do |chip|
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

## Software PWM

`Rgpio::SoftwarePWM` generates PWM in Ruby on any GPIO line. It needs no
dtoverlay and no config.txt entry, which is why the device classes above use it
by default.

```ruby
Rgpio::SoftwarePWM.open(18) do |pwm|
  pwm.frequency  = 100
  pwm.duty_cycle = 0.25
  pwm.enable
  sleep 2
  pwm.pulse_width_us = 1500   # or set the high time directly
end
```

It presents the same interface as `HardwarePWM` — `frequency=`, `duty_cycle=`,
`pulse_width_us=`, `enable`/`disable`, `close` — so the device classes take
either. Pass `pwm: :hardware` on GPIO12/13/18/19 for the peripheral instead:

```ruby
servo = Rgpio::Servo.new(12, pwm: :hardware)   # needs the dtoverlay, see below
led   = Rgpio::PWMLED.new(13, pwm: channel)    # or share a channel you own
```

### Which to use

| | Software PWM | Hardware PWM |
|---|---|---|
| Setup | none | `dtoverlay` in config.txt |
| Lines | any | GPIO12/13/18/19, two at a time on the header |
| Accuracy | 6 us of spread at 50 Hz on an idle Pi 5 | exact |
| Cost | 2.7% of one core per channel at 50 Hz | none |

The generating thread sleeps until shortly before each edge and then spins for
the last `spin_us` (300 by default, capped at 5% of the period), because sleeping
the whole way overshoots a microsecond-scale deadline badly. Spinning holds the
GVL, which is where the CPU figure comes from.

Measured on a Pi 5 with a jumper between two header pins and the kernel's own
edge timestamps (`examples/pwm_jitter.rb`): a 50 Hz 1500 us pulse — a servo's
centre — came out at 1504.9 us with 6.2 us of standard deviation, or about half a
degree of travel. A busy machine widens that: while the main thread holds the
GVL, the generating thread cannot wake. Python has the same limitation with the
GIL, and gpiozero's PWM is software-timed too.

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
require "rgpio"

# gpio: auto-selects chip and channel for GPIO18 on Pi 5
Rgpio::HardwarePWM.open(gpio: 18) do |pwm|
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

### GPIO-to-PWM mapping

The mapping is board-specific and auto-detected from the device-tree model.

**Pi 5 (RP1)** — one 4-channel chip:

| GPIO | Physical pin | RP1 PWM channel |
|---|---|---|
| GPIO12 | 32 | 0 |
| GPIO13 | 33 | 1 |
| GPIO18 | 12 | 2 |
| GPIO19 | 35 | 3 |

**Pi 4 (BCM2711)** — one 2-channel chip; the two pins on a channel are
alternatives (use one at a time):

| GPIO | Physical pin | BCM2711 PWM channel |
|---|---|---|
| GPIO12 | 32 | 0 (PWM0) |
| GPIO18 | 12 | 0 (PWM0) |
| GPIO13 | 33 | 1 (PWM1) |
| GPIO19 | 35 | 1 (PWM1) |

### Manual chip/channel specification

The `gpio:` and `chip: :auto` paths detect the board from the device-tree model
(the resolved family is available as `pwm.board`, e.g. `:pi5` on a Pi 5) and pick
the header PWM chip and channel accordingly. If auto-detection fails, specify the
chip number explicitly:

```ruby
pwm = Rgpio::HardwarePWM.new(chip: 2, channel: 0)
```

You can also force the board family (e.g. when the model string is unusual):

```ruby
pwm = Rgpio::HardwarePWM.new(gpio: 18, board: :pi5)
```

List available chips:

```ruby
Rgpio::HardwarePWM.available_chips
# => [{chip: 0, npwm: 2, path: "/sys/class/pwm/pwmchip0"},
#     {chip: 2, npwm: 4, path: "/sys/class/pwm/pwmchip2"}]
```

---

## I2C Usage

`Rgpio::I2C` talks to a device on a Linux i2c-dev bus (`/dev/i2c-N`). It is
plain `ioctl` work on a character device, so it needs no libgpiod — it works
even where `Rgpio.available?` is `false`.

### Step 1 — Enable the header bus

The 40-pin header bus (GPIO2 = SDA, GPIO3 = SCL) is bus 1, and is off by
default:

```sh
sudo raspi-config nonint do_i2c 0   # or add dtparam=i2c_arm=on to /boot/firmware/config.txt
sudo reboot
```

### Step 2 — Verify

```sh
ls /dev/i2c-1
i2cdetect -y 1      # lists the addresses that answer (i2c-tools package)
```

```ruby
Rgpio::I2C.buses    # => [1, 13, 14]
```

### Step 3 — Talk to a device

```ruby
require "rgpio"

# Block form closes the bus device on exit.
Rgpio::I2C.open(address: 0x48) do |i2c|
  # Write, then read back without releasing the bus (repeated START) — this is
  # what a device with a register pointer expects.
  msb, lsb = i2c.read_register(0x00, 2)

  # Or drive the two halves separately.
  i2c.write(0x03, 0x80)      # write 0x80 to register 0x03
  bytes = i2c.read(2)        # => [Integer, Integer]
end
```

Reads return byte arrays. Writes take integers, strings, or a mix, so a control
byte and a payload can go out in one transaction:

```ruby
i2c.write(0x40, "Hello")     # => 6
```

Failures surface as the kernel's own `Errno` exceptions: `Errno::EREMOTEIO`
when nothing acknowledges the address, `Errno::EBUSY` when a kernel driver
already holds it (pass `force: true` to claim it anyway), `Errno::EACCES` when
the user is not in the `i2c` group.

### Temperature sensor — `Rgpio::ADT7410`

```ruby
sensor = Rgpio::ADT7410.new        # address 0x48 on bus 1
puts sensor.temperature            # => 27.25  (degrees Celsius)
sensor.close
```

The address is set by the A1/A0 pins: 0x48 with both low (the default on the
breakout boards) through 0x4b. The sensor powers up in 13-bit mode, resolving
0.0625 degC; `resolution: 16` resolves 0.0078 degC.

```ruby
sensor = Rgpio::ADT7410.new(address: 0x49, resolution: 16)
sensor.detected?                   # => true when the ID register reports Analog Devices
sensor.resolution = 13             # switch back at runtime
```

The first conversion after power-up takes 240 ms
(`Rgpio::ADT7410::CONVERSION_TIME`); read before it finishes and the register
still holds its 0 degC reset value.

### Character LCD — `Rgpio::ST7032`

For the ST7032-based modules — Akizuki AQM0802 (8x2) and AQM1602 (16x2) — which
answer at 0x3e.

```ruby
lcd = Rgpio::ST7032.new(columns: 8)   # 3.3 V defaults: contrast 0x20, booster on
lcd.message = "Hello\nrgpio"          # clear, then print; a newline is the next row

lcd.move_to(0, 1)                     # column, row
lcd.print("27.2 C".rjust(8))          # overwrite in place — clearing every update flickers
lcd.contrast = 0x28                   # 0..63
lcd.close                             # the panel keeps whatever was written last
```

Text that would run past the last column of a row is dropped rather than
wrapped: the controller's DDRAM addresses are not contiguous between rows, so an
overrun scatters characters into invisible addresses instead of continuing on the
next line.

A panel showing nothing is almost always contrast, which is the one setting the
controller cannot read back — sweep `contrast:` across 0x10..0x38. Modules run at
5 V want the boost converter off (`booster: false`).

---

## SPI Usage

`Rgpio::SPI` talks to a device on a Linux spidev bus (`/dev/spidevB.D`). Like the
I2C support it is `ioctl` work on a character device, so it needs no libgpiod.

### Step 1 — Enable the header bus

SPI0 is off by default. On the header it is GPIO10 (MOSI), GPIO9 (MISO), GPIO11
(SCLK), GPIO8 (CE0) and GPIO7 (CE1):

```sh
sudo raspi-config nonint do_spi 0   # or add dtparam=spi=on to /boot/firmware/config.txt
```

```sh
ls /dev/spidev0.0
```

```ruby
Rgpio::SPI.devices    # => [[0, 0], [0, 1]]  as [bus, chip-select]
```

### Step 2 — Talk to a device

```ruby
Rgpio::SPI.open(bus: 0, device: 0, speed_hz: 1_000_000) do |spi|
  # SPI is full duplex: one byte goes out for every byte that comes in, so
  # #transfer answers with as many bytes as it was given.
  received = spi.transfer([0x06, 0x00, 0x00])

  spi.write(0x40, "Hello")   # transfer, ignoring what came back
  spi.read(4)                # transfer of zeros, keeping what came back
end
```

`mode:` selects clock polarity and phase (0..3), and `speed_hz`, `mode` and
`bits_per_word` can all be changed on an open device. A single transfer can take
a `speed_hz:` of its own.

Failures surface as the kernel's own `Errno` exceptions — `Errno::EACCES` when
the user is not in the `spi` group, `Errno::ENODEV` when the bus is not enabled.

### Analogue input — `Rgpio::MCP3208`

Eight 12-bit channels over SPI, the MCP3204's four channels being the same part
and protocol.

```ruby
adc = Rgpio::MCP3208.new                 # bus 0, CE0, 1 MHz, VREF 3.3 V
adc.read(0)                              # => 0..4095, the raw code
adc.value(0)                             # => 0.0..1.0, a fraction of VREF
adc.voltage(0)                           # => volts
adc.read_all                             # => every channel, consecutively
adc.read(0, differential: true)          # => the CH0/CH1 pair rather than CH0
adc.close
```

```ruby
adc = Rgpio::MCP3208.new(channels: 4, reference_voltage: 5.0, speed_hz: 500_000)
```

Wiring: VDD **and VREF** to 3.3 V, AGND and DGND to ground, CLK/DOUT/DIN to
SCLK/MISO/MOSI, CS to CE0. A forgotten VREF is the usual reason every channel
reads 0 or sticks at full scale.

The clock rate is a matter of correctness, not just speed: the datasheet allows
1 MHz at 2.7 V and 2 MHz at 5 V, and a converter clocked past its sampling rate
answers with values that look plausible and are wrong. The 1 MHz default is
inside the envelope for the 3.3 V supply a Pi provides.

Unconnected channels float and read whatever is nearby; that is not a fault.

---

## Running the examples

All examples require root (or `gpio` group membership):

```sh
# Blink an LED on GPIO4
ruby examples/led.rb

# Print Pressed / Released for a switch on GPIO4
ruby examples/button.rb

# Drive a DC motor forward and backward through a DRV8835
ruby examples/motor.rb

# Fade an LED with PWM on GPIO4
ruby examples/pwm_led.rb

# Cycle a full-colour LED through the colour cube on GPIO17/27/22
ruby examples/rgb_led.rb

# Find the per-channel balance that makes that LED's white look white
ruby examples/rgb_balance.rb

# Sweep a servo on GPIO4, by value and by angle
ruby examples/servo.rb

# Report which PWM chip and channel each header GPIO resolves to
ruby examples/pwm_info.rb

# Print the ADT7410 temperature once a second
ruby examples/temperature.rb

# Write text and a counter to an ST7032 LCD
ruby examples/lcd.rb

# Show the temperature on the LCD — both I2C devices on one bus
ruby examples/lcd_thermometer.rb

# Print all eight channels of an MCP3208
ruby examples/adc.rb

# Dim an LED from a potentiometer through the MCP3208
ruby examples/adc_led.rb
```

`examples/lowlevel/` holds the same LED and button demos written directly
against `Chip` / `LineRequest`, for when you need control the device classes do
not expose:

```sh
sudo ruby examples/lowlevel/blink.rb
sudo ruby examples/lowlevel/button.rb

# The servo driven straight from the PWM peripheral (dtoverlay required)
sudo ruby examples/lowlevel/servo.rb
```

`examples/pwm_jitter.rb` measures what a PWM channel really puts on the line,
using the kernel's edge timestamps and a jumper between two header pins:

```sh
ruby examples/pwm_jitter.rb --hz 50 --duty 0.075 --seconds 5
```

---

## API reference

### `Rgpio`

| Method | Description |
|---|---|
| `.available?` | `true` if `libgpiod.so` was found |
| `.version` | libgpiod version string (e.g. `"2.1.3"`) |

### `Rgpio::Chip`

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

### `Rgpio::LineRequest`

| Method | Description |
|---|---|
| `#get_value(offset)` | `:active` or `:inactive` |
| `#set_value(offset, value)` | Set output level |
| `#get_values(offsets = all)` | Read several lines atomically → `{offset => :active/:inactive}` |
| `#set_values(hash)` | Write several lines atomically from `{offset => value}` |
| `#wait_edge_events(timeout:)` | `true` if event ready |
| `#read_edge_events(timeout:, capacity:)` | Array of event hashes |
| `#release` | Release kernel request |

### `Rgpio::OutputDevice` (and `Rgpio::LED`)

| Method | Description |
|---|---|
| `.new(gpio, active_low:, initial_value:, chip:, consumer:)` | Claim a line as an output |
| `#on` / `#off` / `#toggle` | Drive the line to its active / inactive level |
| `#value` / `#value=` | Current level as `true` / `false` (`#on?` is an alias of `#value`) |
| `#gpio` | Line offset this device drives |
| `#close` / `#closed?` | Release the line (and the chip, if it opened one) |

### `Rgpio::InputDevice` (and `Rgpio::Button`)

| Method | Description |
|---|---|
| `.new(gpio, pull_up:, active_low:, debounce_us:, chip:, consumer:)` | Claim a line as an input; `pull_up:` takes `true` / `false` / `nil` (no bias) |
| `#value` | `true` when the line is at its active level (`#active?`, and `#pressed?` on `Button`) |
| `#when_pressed { }` / `#when_released { }` | `Button` edge callbacks, run on a watcher thread |
| `#gpio` | Line offset this device reads |
| `#close` / `#closed?` | Stop the watcher and release the line |

### `Rgpio::Motor`

| Method | Description |
|---|---|
| `.new(forward:, backward:, chip:, consumer:)` | Claim both lines of a two-input driver |
| `#forward` / `#backward` | Run at full speed in one direction |
| `#stop` | Drop both lines |
| `#close` | Stop, then release both lines |

### `Rgpio::I2C`

| Method | Description |
|---|---|
| `.new(address:, bus: 1, force: false)` | Open `/dev/i2c-N` and claim a 7-bit address |
| `.open(address:, bus:) { \|i2c\| }` | Block form; closes on exit |
| `.buses` | Bus numbers with a `/dev/i2c-N` node |
| `#write(*bytes)` | Write integers / strings in one transaction |
| `#read(count)` | Read `count` bytes → `Array<Integer>` |
| `#write_read(bytes, count)` | Write then read with a repeated START |
| `#read_register(register, count = 1)` | `write_read([register], count)` |
| `#write_register(register, *bytes)` | Write a register in one transaction |
| `#address` / `#bus` / `#path` | What this device was opened on |
| `#close` / `#closed?` | Close the bus device |

### `Rgpio::SPI`

| Method | Description |
|---|---|
| `.new(bus: 0, device: 0, speed_hz:, mode:, bits_per_word:)` | Open `/dev/spidevB.D` |
| `.open(...) { \|spi\| }` | Block form; closes on exit |
| `.devices` | `[bus, chip-select]` of every spidev node |
| `#transfer(bytes, speed_hz:, delay_us:)` | Full-duplex transfer → `Array<Integer>` |
| `#write(*bytes)` | Transfer, ignoring what came back |
| `#read(count)` | Transfer of zeros, keeping what came back |
| `#speed_hz` / `#mode` / `#bits_per_word` (and `=`) | Bus settings |
| `#bus` / `#device` / `#path` | What this device was opened on |
| `#close` / `#closed?` | Close the bus device |

### `Rgpio::MCP3208`

| Method | Description |
|---|---|
| `.new(channels:, reference_voltage:, bus:, device:, speed_hz:, spi:)` | Open the converter; `spi:` shares a bus device |
| `#read(channel, differential: false)` | Raw code, 0..4095 |
| `#value(channel, ...)` | Fraction of VREF, 0.0..1.0 |
| `#voltage(channel, ...)` | Volts |
| `#read_all` | Every channel, sampled consecutively |
| `#channels` / `#reference_voltage` / `#spi` | What it was configured with |
| `#close` / `#closed?` | Close the bus device, if this converter opened it |

### `Rgpio::ADT7410`

| Method | Description |
|---|---|
| `.new(address: 0x48, bus: 1, resolution: 13, i2c: nil)` | Open the sensor; `i2c:` shares an existing bus device |
| `.convert(msb, lsb, resolution = 13)` | Raw register pair → degrees Celsius |
| `#temperature` | Temperature in degrees Celsius (`#value` is an alias) |
| `#raw_temperature` | The two temperature bytes, MSB first |
| `#resolution` / `#resolution=` | 13 or 16 bits |
| `#id` / `#detected?` | ID register, and whether it reports Analog Devices |
| `#i2c` | The bus device readings go through |
| `#close` / `#closed?` | Close the bus device, if this sensor opened it |

### `Rgpio::ST7032`

| Method | Description |
|---|---|
| `.new(address: 0x3e, bus: 1, columns: 8, rows: 2, contrast: 0x20, booster: true, i2c: nil)` | Open and initialise the display |
| `.open(...) { \|lcd\| }` | Block form; closes on exit |
| `#message=(text)` | Clear, then print |
| `#print(text)` | Write at the cursor; a newline moves to the next row |
| `#move_to(col, row = 0)` | Move the cursor (`#set_cursor` is an alias) |
| `#clear` / `#home` | Blank the display / return the cursor |
| `#contrast` / `#contrast=` | 0..63 |
| `#display_on` / `#display_off` | Blank the panel without losing its contents |
| `#command(byte)` / `#write_data(text)` | Raw instruction / display-data transfer |
| `#reset` | Re-run the power-on initialisation sequence |
| `#columns` / `#rows` / `#i2c` | Geometry, and the bus device writes go through |
| `#close` / `#closed?` | Close the bus device, if this display opened it |

### `Rgpio::SoftwarePWM`

| Method | Description |
|---|---|
| `.new(gpio, frequency:, duty_cycle:, spin_us:, chip:, consumer:)` | Claim a line and prepare a channel |
| `.open(gpio, ...) { \|pwm\| }` | Block form; closes on exit |
| `#frequency` / `#frequency=` | Hz, 0.1..10000 |
| `#duty_cycle` / `#duty_cycle=` | 0.0..1.0 (`#duty_ratio` is an alias) |
| `#pulse_width_us` / `#pulse_width_us=` | High time in microseconds |
| `#enable` / `#disable` / `#enabled?` | Start and stop generating |
| `#spin_us` | Microseconds spent spinning before each edge |
| `#close` / `#closed?` | Stop, release the line, close an owned chip |

### `Rgpio::PWMOutputDevice` (and `Rgpio::PWMLED`)

| Method | Description |
|---|---|
| `.new(gpio, frequency:, initial_value:, active_low:, pwm:, chip:, consumer:)` | Drive a line from a PWM channel |
| `#value` / `#value=` | Level, 0.0..1.0 (`#brightness` on `PWMLED`) |
| `#on` / `#off` / `#toggle` | 1.0 / 0.0 / the complement of the current level |
| `#on?` | True when not fully off (`#active?` is an alias) |
| `#frequency` / `#frequency=` | Delegated to the channel |
| `#pwm` | The channel behind this device |
| `#close` / `#closed?` | Stop the channel, releasing it if the device opened it |

### `Rgpio::RGBLED`

| Method | Description |
|---|---|
| `.new(red:, green:, blue:, frequency:, active_low:, balance:, pwm:, chip:, consumer:)` | Three channels as one device |
| `#color` / `#color=` | An r,g,b triple, or a name from `COLORS` |
| `#red` / `#green` / `#blue` (and `=`) | One channel at a time |
| `#balance` / `#balance=` | Per-channel scale under every level asked for |
| `#on` / `#off` / `#toggle` | White / dark / the complement of each channel |
| `#on?` | True when any channel is lit |
| `#channels` | The three `PWMLED`s, by colour |
| `#close` / `#closed?` | Stop all three, close an owned chip |

### `Rgpio::Servo`

| Method | Description |
|---|---|
| `.new(gpio, min_pulse_us:, max_pulse_us:, frequency:, min_angle:, max_angle:, initial_value:, pwm:, chip:, consumer:)` | Claim a line and centre the servo |
| `#value` / `#value=` | -1.0..1.0, or nil to detach |
| `#angle` / `#angle=` | Degrees between `min_angle` and `max_angle` |
| `#min` / `#mid` / `#max` | The ends of the travel and the centre |
| `#pulse_width_us` / `#pulse_width_us=` | The width being sent; assigning one calibrates by hand |
| `#detach` / `#attached?` | Stop the pulses so the horn goes limp / report whether they are running |
| `#close` / `#closed?` | Stop the channel, releasing it if the servo opened it |

### `Rgpio::HardwarePWM`

| Method | Description |
|---|---|
| `.new(gpio:, board:)` | Auto-detect chip/channel for a GPIO pin (board auto-detected) |
| `.new(chip:, channel:)` | Explicit chip/channel |
| `.open(...) { \|pwm\| }` | Block form; closes on exit |
| `.available_chips` | List sysfs PWM chips |
| `.detect_board` | Board family from the device-tree model (`:pi5` / `:pi4` / `:unknown`) |
| `#board` | Resolved board family |
| `#frequency=` / `#frequency` | Hz |
| `#duty_cycle=` / `#duty_ratio` | 0.0–1.0 ratio |
| `#pulse_width_us=` / `#pulse_width_us` | Microseconds |
| `#enable` / `#disable` | Start/stop PWM output |
| `#close` | Disable and unexport |

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  LED / Button / Motor / PWMLED / RGBLED / Servo         │  device classes (gpiozero-style)
│  ADT7410 / ST7032 / MCP3208                             │  (one object per part)
├─────────────────────────────────────────────────────────┤
│  Rgpio::Chip / LineRequest                              │  OOP wrappers (this gem)
├──────────────────┬──────────────────┬───────────────────┤
│  Native (fiddle) │  HardwarePWM     │  I2C / SPI        │  libgpiod.so / sysfs PWM / i2c-dev
│  SoftwarePWM     │                  │                   │  (PWM timed in Ruby on any line)
└──────────────────┴──────────────────┴───────────────────┘
     libgpiod v2 ABI    Linux PWM sysfs    /dev/i2c-N, /dev/spidev ioctl
```

- **Layer 1 (`Native`)** — raw `fiddle` declarations of the libgpiod C functions
- **Layer 2 (`Chip`, `LineRequest`, `HardwarePWM`, `SoftwarePWM`, `I2C`, `SPI`)** — Ruby-idiomatic wrappers
- **Layer 3 (`LED`, `Button`, `Motor`, `PWMLED`, `RGBLED`, `Servo`, `ADT7410`,
  `ST7032`, `MCP3208`)** — one object per piece of hardware

---

## Project status

- **Released changes:** [CHANGELOG.md](CHANGELOG.md)
- **Roadmap, planned APIs, and multi-board validation status:** [PLAN.md](PLAN.md)

---

## License

[MIT](LICENSE)
