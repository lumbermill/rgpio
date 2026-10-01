require_relative "lib/rgpio/version"

Gem::Specification.new do |spec|
  spec.name        = "rgpio"
  spec.version     = Rgpio::VERSION
  spec.authors     = ["ITO Yosei"]
  spec.email       = ["y-itou@lumber-mill.co.jp"]
  spec.summary     = "GPIO, PWM, I2C and SPI on Raspberry Pi, via libgpiod v2 and the Linux character devices"
  spec.description = "Control a Raspberry Pi's hardware from Ruby. GPIO goes through libgpiod v2 — the " \
                     "Linux GPIO character device (uAPI v2) — rather than the deprecated sysfs interface. " \
                     "PWM is either the hardware peripheral through sysfs or timed in Ruby on any line; " \
                     "I2C and SPI are ioctl calls on /dev/i2c-N and /dev/spidev, needing no libgpiod at " \
                     "all. On top sits a gpiozero-style device layer: LED, Button, Motor, PWMLED, RGBLED, " \
                     "Servo, and drivers for the ADT7410 temperature sensor, ST7032 character LCD and " \
                     "MCP3208 ADC. Bound through the stdlib `fiddle`, which is built with the interpreter " \
                     "and so matches any Pi's architecture, unlike the precompiled `ffi` gem."
  spec.homepage    = "https://github.com/lumbermill/rgpio"
  spec.license     = "MIT"

  spec.required_ruby_version = ">= 3.3"

  # The guide and PLAN.md ship too: the README points at the guide for the full
  # manual, and at PLAN.md for the roadmap and what has been verified on which
  # board.
  spec.files = Dir["lib/**/*.rb", "examples/**/*.rb", "LICENSE", "README.md", "CHANGELOG.md", "PLAN.md",
                   "docs/**/*.md"]

  # `fiddle` is a default gem on Ruby <= 3.4 and a bundled gem from 3.5 on;
  # declaring it keeps the dependency satisfied either way. Unlike the
  # precompiled `ffi` gem, fiddle is built with the interpreter and therefore
  # works on ARMv6 (Pi Zero / Pi 1).
  spec.add_dependency "fiddle", ">= 1.0"

  spec.add_development_dependency "minitest"
  spec.add_development_dependency "rake"
  spec.add_development_dependency "rubocop", "~> 1.90"

  spec.metadata["source_code_uri"]       = "https://github.com/lumbermill/rgpio"
  spec.metadata["changelog_uri"]         = "https://github.com/lumbermill/rgpio/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"]       = "https://github.com/lumbermill/rgpio/issues"
  spec.metadata["rubygems_mfa_required"] = "true"
end
