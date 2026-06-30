#!/usr/bin/env ruby
# frozen_string_literal: true

# Read a button connected to GPIO27.
# Prints a line each time the button is pressed or released.
#
# Wiring (active-low with internal pull-up):
#   Pi 5 pin 13 (GPIO27) -- one leg of button
#   Button other leg     -- GND (pin 14 or any GND pin)
#
# Run:
#   ruby examples/button.rb
#
# Ctrl-C to stop.

require_relative "../lib/rgpio"

GPIO_BUTTON = 27
DEBOUNCE_S  = 0.050   # 50 ms安定でイベント確定
POLL_S      = 0.005   # エッジイベント待ちのタイムアウト（＝ポーリング間隔）

puts "libgpiod version: #{Rgpio.version}"
puts "Watching GPIO#{GPIO_BUTTON} for button events. Press Ctrl-C to stop."

# No path given → auto-detect the header GPIO controller (Pi 5 / 4 / Zero).
Rgpio::Chip.open do |chip|
  puts "Chip: #{chip.path} #{chip.label}"

  request = chip.request_lines(
    offsets:    [GPIO_BUTTON],
    direction:  :input,
    edge:       :both,      # エッジ検出を有効にしてカーネルが値を更新し続けるようにする
    bias:       :pull_up,
    active_low: true,
    consumer:   "rgpio-button"
  )

  # エッジイベントで「変化があった」と気付き、get_valueで「実際の状態」を読む。
  # イベントのtype（:rising/:falling）は使わない。
  # これによりクロック差・イベント順序・ノイズ問題を全て回避する。
  stable          = request.get_value(GPIO_BUTTON)
  candidate       = stable
  candidate_since = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  begin
    loop do
      # エッジイベントが来たら即座に、なければ POLL_S 後に抜ける
      # バッファを読み切ることで溢れを防ぐ（イベント内容は捨てる）
      request.read_edge_events(timeout: POLL_S)

      current = request.get_value(GPIO_BUTTON)
      now     = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      if current != candidate
        # 状態が変わった → タイマーリセット
        candidate       = current
        candidate_since = now
      elsif current != stable && (now - candidate_since) >= DEBOUNCE_S
        # DEBOUNCE_S 間ずっと同じ → 確定して報告
        stable = current
        label  = stable == :active ? "PRESSED " : "RELEASED"
        puts "[#{now.round(3)} s] GPIO#{GPIO_BUTTON} #{label}"
      end
    end
  rescue Interrupt
    puts "\nStopped."
  ensure
    request.release
  end
end
