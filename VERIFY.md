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

---

# Phase 3c 実機チェックリスト（PWM）

ソフトPWM（`Rgpio::SoftwarePWM`）を既定にした `PWMLED` / `RGBLED` / `Servo` です。
**config.txt も dtoverlay も不要**で、どのGPIOでも使えます。

## 0. 波形そのもの（済）

ヘッダのGPIO23（16番ピン）とGPIO24（18番ピン）をジャンパ1本で直結し、カーネルの
エッジタイムスタンプでパルス幅を実測しました。サーボもLEDも繋がずにクラスの
写像を確認できるので、配線を変える前にここが通ることを確かめます。

```bash
ruby examples/pwm_jitter.rb --hz 50 --duty 0.075 --seconds 5
```

- [x] 50Hz/1500µs で 平均1504.9µs・標準偏差6.2µs（2026-09-27）
- [x] `Servo` の value −1/0/+1 → 1004.8 / 1505.2 / 2004.6 µs、`angle = 45` → 1756.6 µs
- [x] `PWMLED` の value 0.25/0.50/0.75 → duty 25.1 / 50.1 / 75.1 %、`active_low` で反転
- [x] `RGBLED` の1チャンネルを0.6にして 60.1%（他2スレッド稼働中）
- [x] 全項目で目標より 4〜8µs 長い一定オフセット（サーボで0.4°、校正で吸収できる範囲）

## 1. LEDの明るさ（PWMLED）

配線: Phase 3a の `examples/led.rb` と同じ。`GPIO4(7番)` → 1kΩ → LED長足 /
LED短足 → `GND(6番)`

```bash
ruby examples/pwm_led.rb
```

- [x] 3往復、なめらかに明るく暗くなる（2026-09-28）
- [x] 5% / 25% / 50% / 100% の固定保持がそれぞれ見分けられ、暗いところでもちらつかない
- [x] `value` を1回呼ぶだけで明るさが維持される
- [x] Ctrl+C で消灯して止まる

**この確認のやり方**: 例は各段階を `$stdout.sync` で実況表示するので、**自分の端末で
実行**して端末の表示と実物を見比べてください。人に代わりに実行させると、表示が
出るタイミングと手元の変化がずれて確認になりません。

## 2. フルカラーLED（RGBLED）

配線（カソードコモン。長い足が共通でGNDへ）:
`GPIO17(11番)` → 1kΩ → 赤 / `GPIO27(13番)` → 1kΩ → 緑 / `GPIO22(15番)` → 1kΩ → 青 /
共通足 → `GND(9番)`

アノードコモンのLEDなら共通足を3.3Vに入れて `active_low: true` を付けます。

```bash
ruby examples/rgb_led.rb
```

- [x] 赤→緑→青→黄→シアン→マゼンタ→白 と2秒ごとに変わる（2026-09-28）
- [x] 色名どおりの色に見える
- [x] 赤↔青のフェードがなめらか（3スレッドのソフトPWMが同時稼働）
- [x] **白が青っぽい → `balance: [1.0, 0.8, 0.8]` で補正**（赤が弱いチャンネル。
      個体差なので `ruby examples/rgb_balance.rb` で各自校正する）
- [x] Ctrl+C で消灯して止まる
- [x] 補正後は黄色もはっきりした（混色の比率が正しくなった）

## 3. サーボ（Servo）

配線: `GPIO4(7番)` → 信号線 / `5V(2番か4番)` → 電源 / `GND(6番)` → GND

負荷がかかるとPiの5Vが落ちることがあります。**スイープ中にPiが再起動するようなら
サーボは別電源にしてGNDだけ共通**にしてください。

```bash
ruby examples/servo.rb
```

- [x] 中央 → 端 → 逆端 を2往復（2026-09-28）
- [x] `angle` スイープが**カクカクせず連続的**に動く（Python版との差が出る項目）
- [x] `detach` でホーンが自由に回る（力が抜ける）
- [x] Ctrl+C で止まる
- [ ] 可動端でうなり・発熱があれば `min_pulse_us` / `max_pulse_us` を狭める（今回は不要だった）

## 4. Python版との比較（任意）

同じサーボで gpiozero と比べると、Python側は200µs刻み（180°サーボで約18°刻み）
なので、`angle` を1°ずつ動かしても**追従しない角度がある**のが見えます。

```bash
python3 -c "
from gpiozero import Servo; from time import sleep
s = Servo(4)
for v in [-1, -0.9, -0.8, -0.7]:
    s.value = v; print(v); sleep(1)
"
```

- [ ] Python版は −1.0 と −0.9 で同じ位置に見える（Ruby版は動く）

## 全部 ✅ になったら

2026-09-28 に完了したので、以下を実施済みです。

- [x] README.md に `SoftwarePWM` / `PWMLED` / `RGBLED` / `Servo` を追記（確定仕様に昇格）
- [x] PLAN.md の 3c を ✅ に
- [x] CHANGELOG を確認してコミット

4番（Python版との比較）は任意のまま残してあります。

## つまずいたら

- LEDがちらつく → `PWMLED.new(4, frequency: 400)` など周波数を上げる
- サーボが震える → 他プロセスの負荷でGVLが取られている。`spin_us` は既定300µsが最良。
  それでも駄目なら `pwm: :hardware`（GPIO12/13/18/19、要dtoverlay）
- `Device or resource busy` → そのラインを別プロセスが掴んでいる。`sudo lsof /dev/gpiochip0`
- GPIO2/3 を使いたい → I2Cが有効だとSDA/SCLに取られている。Control Centre で切る

---

# Phase 3d 実機チェックリスト（SPI + MCP3208）

## 0. SPIバスを有効化（済）

Control Centre で有効化済みです（`/dev/spidev0.0`、GPIO9/10/11 が MISO/MOSI/SCLK、
GPIO8 は CE0 をGPIOとして制御するため出力Highに見えます — どちらも正常）。

- [x] `ls /dev/spidev0.0` がある（2026-09-27）

## 1. データ経路（ループバック・済）

**19番ピン（GPIO10 / MOSI）と 21番ピン（GPIO9 / MISO）をジャンパで直結。** 同じ列の
隣同士です。MISO未接続だと送っても `00` が返るだけで、実装が間違っていても同じ
見え方になるので、この確認は省略できません。

- [x] 6バイトパターン / 64バイト / 1バイト / String引数 がすべて一致（2026-09-28）
- [x] 100 kHz・1・4・16・32 MHz すべて一致
- [x] モード 0/1/2/3 すべて一致
- [x] `read(4)` がゼロ送信、`write` が送信バイト数を返す

## 2. MCP3208（12bit・8ch）

ループバックのジャンパを外してから配線します。ICの向きは切り欠き側が1番ピン。

| MCP3208 | 接続先 |
|---|---|
| 1番 (CH0) | 可変抵抗のワイパー（真ん中） |
| 9番 (DGND) | GND |
| 10番 (CS) | 24番ピン（GPIO8 / CE0） |
| 11番 (DIN) | 19番ピン（GPIO10 / MOSI） |
| 12番 (DOUT) | 21番ピン（GPIO9 / MISO） |
| 13番 (CLK) | 23番ピン（GPIO11 / SCLK） |
| 14番 (AGND) | GND |
| 15番 (VREF) | 3.3V |
| 16番 (VDD) | 3.3V |

可変抵抗（**103 = 10kΩ を推奨**。102 = 1kΩ だと 3.3mA 流れ続ける）の残り2本を
3.3V と GND へ。

```bash
ruby examples/adc.rb
```

- [x] CH0 が可変抵抗を回すと全域で動く（2026-09-29。16分割した区間を16/16通過、
      min 1 〜 max 3929、550サンプル中245の異なる値）
- [x] 静止時のばらつきは 0.42 LSB = 0.34 mV
- [x] 100 kHz 〜 2 MHz で読み値が変わらない（4 MHz も今回は一致した）
- [x] 未接続のチャンネルは 0〜10 程度の浮いた値（故障ではない）
- [ ] Ctrl+C で止まる（`examples/adc.rb` 実行時に確認）

## 3. 可変抵抗でLEDを調光（3c との合わせ技）

`GPIO4(7番)` → 1kΩ → LED長足 / 短足 → `GND` を追加。

```bash
ruby examples/adc_led.rb
```

- [ ] 可変抵抗を回すとLEDの明るさが追従する
- [ ] 端で消灯、逆端で最大
- [ ] 端末のバーグラフが滑らかに動く（値が飛ばないか）

## 全部 ✅ になったら

- [ ] README.md に `Rgpio::SPI` / `Rgpio::MCP3208` を追記（確定仕様に昇格）
- [ ] PLAN.md の 3d を ✅ に
- [ ] CHANGELOG を確認してコミット

## つまずいたら

- 全チャンネル `0` または `4095` 固定 → CS/DIN/DOUT/CLK のどれかが繋がっていない。
  VREF と VDD の両方に 3.3V が来ているかも確認（VREFを忘れやすい）
- 値が飛ぶ・上位で張り付く → クロックが速すぎる。`speed_hz: 500_000` で試す
  （データシートは 2.7V で 1MHz、5V で 2MHz。**速すぎると「もっともらしい間違った値」
  が返る**ので、疑うのはまずここ）
- `Errno::EACCES` → `sudo usermod -aG spi $USER` して入り直す
- 値が反転している → 可変抵抗の 3.3V と GND が逆
