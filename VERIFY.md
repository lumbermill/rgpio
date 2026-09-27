# Phase 3a 実機チェックリスト

Pi 5 上で上から順に。配線は全部ブレッドボード1枚で済みます。

## 準備

```bash
cd ~/sources/rgpio && git pull
ruby -Ilib -e 'require "rgpio"; p Rgpio.available?, Rgpio.version'
```

- [x] `true` とバージョン文字列が出た（`false` なら `sudo apt install libgpiod3`）

---

## 1. LED点滅

配線: `GPIO4(7番ピン)` → 1kΩ → LEDの長い足 / LEDの短い足 → `GND(6番ピン)`

```bash
ruby examples/led.rb
```

- [x] 1秒間隔で5回点滅した

---

## 2. スイッチ

配線: `3.3V(1番ピン)` → スイッチ → 1kΩ → `GPIO4(7番ピン)`

```bash
ruby examples/button.rb
```

- [x] 押すと `Pressed`、離すと `Released`
- [x] 1回押して1行だけ（何行も出たらデバウンスが効いていない）
- [x] Ctrl+C でエラーを吐かずに止まる

---

## 3. モーションセンサ（対象外・保留）

PIRモジュールの調達が安定しないため、Phase 3a の確認対象から外しました。
`MotionSensor` クラスと `examples/motion_sensor.rb` はそのまま残していますが、
実機確認が済むまで README には載せません（PLAN.md の Phase 3 を参照）。
モジュールが手に入ったら以下で再開できます。

配線: `VCC`→5V / `GND`→GND / `OUT`→`GPIO4`

```bash
ruby examples/motion_sensor.rb
```

- [ ] センサの前で動くと `motion detected!`

---

## 4. モーター（DRV8835）

配線: `AIN1`→`GPIO2` / `AIN2`→`GPIO14` / `VCC`→3.3V / `VM,GND`→モータ電源 /
`AOUT1`,`AOUT2`→モーターの端子2本

モーターの片方をGNDに落とすと正転しかしません（逆転時は両端がGND電位になるため）。
必ず `AOUT1`/`AOUT2` の2本で挟んでください。

```bash
ruby examples/motor.rb
```

- [x] 5秒ごとに正転・逆転が切り替わる
- [x] Ctrl+C でモーターが止まる

---

## 5. active_low の確認（ここが本命）

2番の配線のまま。`active_low: true` を付けると論理が反転するはずなので、
**押したときに `released` が出れば仮定どおり**です。

```bash
ruby -Ilib -e 'require "rgpio"; b = Rgpio::Button.new(4, active_low: true); b.when_pressed { puts "pressed" }; b.when_released { puts "released" }; puts "press the switch (Ctrl-C to stop)"; Rgpio.pause; b.close'
```

- [x] 押したとき `released` と出た → 仮定どおり。何もしなくてOK
- [ ] 押したとき `pressed` と出た → カーネルがエッジを反転していない。
      `InputDevice#watch_loop` の rising/inactive の対応を直す必要あり

---

## 全部 ✅ になったら

モーションセンサ（3番）を除いて完了したので、以下を実施済みです。

- [x] README.md に高レベルAPIの節を追記（確定仕様に昇格）
- [x] PLAN.md の 3a を ✅ に、「Open questions」の active_low の項目を削除
- [x] コミット

## つまずいたら

- `Permission denied` → `sudo usermod -aG gpio $USER` して入り直す
- `Device or resource busy` → 他のプロセスがそのラインを掴んでいる。`sudo lsof /dev/gpiochip0` で確認

---

# Phase 3b 実機チェックリスト（I2C）

温度センサ（ADT7410）とLCD（AQM0802 / ST7032）。配線は4本とも共通で、
2つのモジュールを同じ `3.3V / GND / SDA / SCL` にぶら下げます。

| ヘッダピン | 信号 | 接続先 |
|---|---|---|
| 1番 | 3.3V | VDD（センサ・LCD 両方） |
| 9番 | GND | GND（センサ・LCD 両方） |
| 3番 | GPIO2 / SDA | SDA（センサ・LCD 両方） |
| 5番 | GPIO3 / SCL | SCL（センサ・LCD 両方） |

## 0. ヘッダのI2Cバスを有効化（済）

Raspberry Pi の Control Centre（設定アプリ）のインターフェイス設定で I2C を
有効化済みです。再起動は不要で、その場で `/dev/i2c-1` が生えました。

```bash
ls /dev/i2c-1
pinctrl get 2,3          # GPIO2 = SDA1 / GPIO3 = SCL1 (a3) になっていること
i2cdetect -y 1
ruby -Ilib -e 'require "rgpio"; p Rgpio::I2C.buses'
```

- [x] `/dev/i2c-1` がある（2026-09-23、Control Centre で有効化）
- [x] `Rgpio::I2C.buses` に `1` が含まれる（`[1, 13, 14]`）
- [x] `i2cdetect -y 1` に `48`（センサ）と `3e`（LCD）が出た（2026-09-27）

## 1. バス層そのもの（配線不要・確認済み）

HDMIのDDC（EDID ROM）を読んで、ioctl と構造体パッキングを確認済みです。
配線を触らずにいつでも再実行できます。

```bash
ruby -Ilib -e '
require "rgpio"
i2c = Rgpio::I2C.new(address: 0x50, bus: 13)
edid = i2c.write_read([0x00], 128)
puts edid.first(8).map { |b| format("%02x", b) }.join(" ")
puts((edid.sum % 256).zero? ? "checksum ok" : "checksum BAD")
i2c.close'
```

- [x] `00 ff ff ff ff ff ff 00` + `checksum ok`（2026-09-23 確認、モニタ接続時のみ）

## 2. 温度センサ ADT7410

```bash
ruby examples/temperature.rb
```

- [x] `ADT7410 at 0x48, ID 0xcb, 13-bit mode` が出た
- [x] 1秒ごとに室温らしい値（26〜27℃）が出た
- [x] 0.0625℃刻みで動いた
- [x] Ctrl+C でエラーを吐かずに止まった

16bitモードも確認する場合:

```bash
ruby -Ilib -e 'require "rgpio"; s = Rgpio::ADT7410.new(resolution: 16); sleep 0.3; p s.resolution, s.temperature; s.close'
```

- [x] `16` と同じ温度、刻みが 0.0078℃ になった（13bit への戻しも確認）

## 3. LCD AQM0802（ST7032）

AQM1602（16桁）の場合は `examples/lcd.rb` の `COLUMNS = 8` を `16` に。

```bash
ruby examples/lcd.rb
```

- [x] 2行とも既定のコントラスト（0x20）ではっきり表示された — AQM0802（8桁×2行）
- [x] `move_to` で行ごとに書き換えできた
- [ ] 薄い・出ないときは `Rgpio::ST7032.new(contrast: 0x28)` など 0x10〜0x38 で
      振る（5V版モジュールなら `booster: false` も試す）— 今回は調整不要だった

## 4. センサとLCDの同居

```bash
ruby examples/lcd_thermometer.rb
```

- [x] LCDに `Temp` と温度が1秒ごとに更新された
- [x] 端末にも同じ値が出た（2つの `I2C` オブジェクトが同じバスで喧嘩しない）
- [x] Ctrl+C でLCDがクリアされて止まった
- [x] 毎秒 `clear` するとちらつくので、ラベルは1回だけ書いて値を上書きする形に修正

## 全部 ✅ になったら

2026-09-27 に完了したので、以下を実施済みです。

- [x] README.md に `Rgpio::ADT7410` / `Rgpio::ST7032` を追記（確定仕様に昇格）
- [x] PLAN.md の 3b を ✅ に、「Not yet validated」から2クラスを削除
- [x] CHANGELOG を確認してコミット

残っている未確認: AQM1602（16桁）、5V版モジュール（`booster: false`）、
0℃以下の温度（変換の負値側）。

## つまずいたら

- `Errno::ENOENT` / `/dev/i2c-1 not found` → 0番が未実施。再起動を忘れていないか
- `Errno::EACCES` → `sudo usermod -aG i2c $USER` して入り直す
- `Errno::EREMOTEIO` → そのアドレスが応答していない。配線（SDA/SCL逆、GND浮き）と
  `i2cdetect -y 1` を確認。モジュール側のプルアップ抵抗の有無も確認
- `Errno::EBUSY` → カーネルドライバがそのアドレスを掴んでいる。`force: true` で奪える
- 温度が `0.0000` から動かない → 電源投入直後の変換待ち（240ms）中に読んでいるか、
  SDA/SCL が入れ替わっている
- LCDが真っ黒／真っ白のまま → ほぼコントラスト。コントラストだけは読み戻せないので
  値を振って確かめるしかない
