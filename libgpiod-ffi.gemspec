require_relative 'lib/libgpiod_ffi/version'

Gem::Specification.new do |spec|
  spec.name        = 'libgpiod-ffi'
  spec.version     = LibgpiodFFI::VERSION
  spec.authors     = ['ITO Yosei']
  spec.email       = ['y-itou@lumber-mill.co.jp']
  spec.summary     = 'Ruby bindings for libgpiod v2 (Linux GPIO character device)'
  spec.description = 'GPIO input/output and hardware PWM control on Raspberry Pi via libgpiod v2. ' \
                     'Uses the modern Linux GPIO character device API (uAPI v2) instead of the deprecated ' \
                     'sysfs interface. Bound through the stdlib `fiddle` so it works on every Pi, ' \
                     'including ARMv6 boards (Pi Zero / Pi 1).'
  spec.homepage    = 'https://github.com/lumbermill/libgpiod-ffi'
  spec.license     = 'MIT'

  spec.required_ruby_version = '>= 3.4'

  spec.files = Dir['lib/**/*.rb', 'examples/**/*.rb', 'LICENSE', 'README.md']

  # `fiddle` is a default gem on Ruby <= 3.4 and a bundled gem from 3.5 on;
  # declaring it keeps the dependency satisfied either way. Unlike the
  # precompiled `ffi` gem, fiddle is built with the interpreter and therefore
  # works on ARMv6 (Pi Zero / Pi 1).
  spec.add_dependency 'fiddle', '>= 1.0'

  spec.add_development_dependency 'minitest'
  spec.add_development_dependency 'rake'

  spec.metadata['rubygems_mfa_required'] = 'true'
end
