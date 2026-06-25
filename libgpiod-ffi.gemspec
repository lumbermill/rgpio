require_relative 'lib/libgpiod_ffi/version'

Gem::Specification.new do |spec|
  spec.name        = 'libgpiod-ffi'
  spec.version     = LibgpiodFFI::VERSION
  spec.authors     = ['ITO Yosei']
  spec.email       = ['y-itou@lumber-mill.co.jp']
  spec.summary     = 'Ruby FFI bindings for libgpiod v2 (Linux GPIO character device)'
  spec.description = 'GPIO input/output and hardware PWM control on Raspberry Pi via libgpiod v2 FFI. ' \
                     'Uses the modern Linux GPIO character device API (uAPI v2) instead of the deprecated ' \
                     'sysfs interface. Phase 1 targets Raspberry Pi 5 with Debian Trixie.'
  spec.homepage    = 'https://github.com/lumbermill/libgpiod-ffi'
  spec.license     = 'MIT'

  spec.required_ruby_version = '>= 3.4'

  spec.files = Dir['lib/**/*.rb', 'examples/**/*.rb', 'LICENSE', 'README.md']

  spec.add_dependency 'ffi', '~> 1.15'

  spec.add_development_dependency 'minitest'
  spec.add_development_dependency 'rake'

  spec.metadata['rubygems_mfa_required'] = 'true'
end
