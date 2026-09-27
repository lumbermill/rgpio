#!/usr/bin/env ruby

# Measure how accurate a PWM waveform really is, using the kernel's own edge
# timestamps. A diagnostic, not a demo — nothing here is part of the gem's API.
#
# Wiring: one jumper between two header pins.
#   GPIO23 (pin 16, output) ---- GPIO24 (pin 18, input)
#
# Driving a GPIO output straight into a GPIO input is safe; no resistor needed.
#
# Run (Ruby SoftwarePWM, generated in a forked process so the measuring loop
# does not compete with it for the GVL):
#   ruby examples/pwm_jitter.rb --hz 50 --duty 0.075 --seconds 5
#
# Run (measure something else driving the pin — e.g. Python gpiozero, or
# HardwarePWM wired from GPIO12):
#   ruby examples/pwm_jitter.rb --external --seconds 5
#
# What the numbers mean: `pulse` is the high time a servo reads as its position
# (1 us is about 0.09 degrees on a 180-degree servo), `period` is the frame
# rate. Spread matters more than the mean — a mean that is 3 us off is a fixed
# offset you can calibrate out, while a 200 us spread is visible twitching.

require_relative "../lib/rgpio"

options = {
  out: 23, in: 24, hz: 50.0, duty: 0.075, seconds: 5.0,
  spin: Rgpio::SoftwarePWM::DEFAULT_SPIN_US, external: false,
}

ARGV.each_with_index do |arg, i|
  case arg
  when "--out" then options[:out] = ARGV[i + 1].to_i
  when "--in" then options[:in] = ARGV[i + 1].to_i
  when "--hz" then options[:hz] = ARGV[i + 1].to_f
  when "--duty" then options[:duty] = ARGV[i + 1].to_f
  when "--seconds" then options[:seconds] = ARGV[i + 1].to_f
  when "--spin" then options[:spin] = ARGV[i + 1].to_i
  when "--external" then options[:external] = true
  when "--help", "-h"
    puts File.read(__FILE__).lines.grep(/^#/).join
    exit 0
  end
end

def stats(samples)
  return nil if samples.empty?

  sorted = samples.sort
  mean = samples.sum / samples.size.to_f
  variance = samples.sum { |v| (v - mean)**2 } / samples.size
  {
    n: samples.size, mean: mean, sd: Math.sqrt(variance),
    min: sorted.first, p50: sorted[sorted.size / 2],
    p99: sorted[(sorted.size * 0.99).floor], max: sorted.last,
  }
end

def report(label, target_us, samples)
  s = stats(samples)
  return puts("#{label}: no samples") unless s

  errors = samples.map { |v| (v - target_us).abs }
  e = stats(errors)
  puts format("%-7s target %8.1f us   n=%d", label, target_us, s[:n])
  puts format("          measured  mean %8.1f   sd %6.1f   min %8.1f   p50 %8.1f   max %8.1f",
              s[:mean], s[:sd], s[:min], s[:p50], s[:max])
  puts format("          |error|   mean %8.1f   p50 %6.1f   p99 %8.1f   max %8.1f",
              e[:mean], e[:p50], e[:p99], e[:max])
end

# Collect edge events for `seconds`, then report pulse widths and periods.
def measure(gpio, seconds, target_period_us, target_pulse_us)
  events = []
  Rgpio::Chip.open do |chip|
    request = chip.request_lines(offsets: [gpio], direction: :input, edge: :both,
                                 bias: :disabled, consumer: "pwm_jitter")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      events.concat(request.read_edge_events(timeout: 0.05, capacity: 64))
    end
    request.release
  end

  pulses = []
  periods = []
  last_rise = nil
  events.each do |event|
    if event[:type] == :rising
      periods << ((event[:timestamp_ns] - last_rise) / 1000.0) if last_rise
      last_rise = event[:timestamp_ns]
    elsif last_rise
      pulses << ((event[:timestamp_ns] - last_rise) / 1000.0)
    end
  end

  puts "edges: #{events.size}"
  report("pulse", target_pulse_us, pulses)
  report("period", target_period_us, periods)

  dropped = periods.count { |p| p > target_period_us * 1.5 }
  puts format("dropped/late cycles (period > 1.5x target): %d of %d", dropped, periods.size)
end

period_us = 1_000_000.0 / options[:hz]
pulse_us = period_us * options[:duty]

puts "libgpiod #{Rgpio.version}  |  measuring GPIO#{options[:in]}, #{options[:seconds]} s"

if options[:external]
  puts "generator: external (not driven by this script)"
  measure(options[:in], options[:seconds], period_us, pulse_us)
else
  puts format("generator: Rgpio::SoftwarePWM on GPIO%d, %g Hz, duty %.4f, spin_us %d (forked)",
              options[:out], options[:hz], options[:duty], options[:spin])
  ready_r, ready_w = IO.pipe

  pid = fork do
    ready_r.close
    pwm = Rgpio::SoftwarePWM.new(options[:out], frequency: options[:hz], duty_cycle: options[:duty],
                                                spin_us: options[:spin], consumer: "pwm_jitter_gen")
    pwm.enable
    ready_w.puts "ready"
    ready_w.close
    sleep options[:seconds] + 1.5
    pwm.close
  end

  ready_w.close
  ready_r.gets
  ready_r.close
  sleep 0.2 # let the first few cycles settle before sampling

  begin
    measure(options[:in], options[:seconds], period_us, pulse_us)
  ensure
    Process.waitpid(pid)
  end
end
