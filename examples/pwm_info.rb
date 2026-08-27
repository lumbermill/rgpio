#!/usr/bin/env ruby
# frozen_string_literal: true

# Non-destructive hardware-PWM diagnostic.
#
# Prints the detected board, the PWM chips present in sysfs (with their device
# address and channel count), and — WITHOUT exporting anything — which chip and
# channel each header GPIO would resolve to. Handy for validating board support
# (e.g. Pi 4) before driving a real signal.
#
# Run (no root needed — it only reads sysfs):
#   ruby examples/pwm_info.rb

require_relative "../lib/rgpio"

HW = Rgpio::HardwarePWM

# Read-only preview of HardwarePWM#detect_pwm_chip! — never exports a channel.
def resolve_chip(board, chips)
  profile = HW::PWM_CHIP_PROFILE[board]
  if profile
    by_address = chips.find do |c|
      (File.readlink(c[:path]) rescue "").include?(profile[:address])
    end
    return [by_address[:chip], "address #{profile[:address]}"] if by_address

    by_npwm = chips.find { |c| c[:npwm] == profile[:npwm] }
    return [by_npwm[:chip], "npwm==#{profile[:npwm]}"] if by_npwm
  end
  return [chips.first[:chip], "only chip"] if chips.size == 1

  [nil, "ambiguous — pass chip: explicitly"]
end

puts "libgpiod:      #{Rgpio.available? ? Rgpio.version : "not available"}"
puts "board model:   #{HW.board_model.inspect}"

board = HW.detect_board
puts "detected board: #{board.inspect}"
puts

chips = HW.available_chips
if chips.empty?
  puts "No PWM chips under #{HW::PWM_SYSFS_ROOT}. Enable the PWM dtoverlay first."
  exit 1
end

puts "PWM chips:"
chips.each do |c|
  link = File.readlink(c[:path]) rescue "(not a symlink)"
  puts "  pwmchip#{c[:chip]}  npwm=#{c[:npwm]}  ->  #{link}"
end
puts

chip_num, why = resolve_chip(board, chips)
puts "chip auto-detection for #{board.inspect}: " \
     "#{chip_num ? "pwmchip#{chip_num}" : "FAILED"} (#{why})"
puts

table = HW::GPIO_TO_PWM_CHANNEL[board]
if table
  puts "header GPIO -> channel (#{board.inspect}):"
  table.each do |gpio, channel|
    puts "  GPIO#{gpio}  ->  pwmchip#{chip_num || "?"}, channel #{channel}"
  end
else
  puts "No header GPIO -> channel mapping for board #{board.inspect}. " \
       "Pass board: :pi5/:pi4 or chip:/channel: explicitly."
end
