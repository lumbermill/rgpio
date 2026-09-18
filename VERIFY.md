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
