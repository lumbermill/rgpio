# libgpiod-ffi 計画書

## 概要

Raspberry Pi の GPIO を、Ruby の `ffi` gem 経由で libgpiod(Linux kernel の GPIO character device, `/dev/gpiochipN`)を直接バインドして操作するための gem。Cの拡張(ext)は書かず、`ffi` で libgpiod.so の関数を宣言して呼び出す方式を取る。GPIO に加えて、Linux PWM サブシステム経由のハードウェア PWM 制御も対象に含める。

- gem 名: `libgpiod-ffi`(確定)。rubygems.org への登録は、最低限の GPIO 入出力とハードウェア PWM が動作してから行う。
- ライセンス: MIT。

## 背景・課題

- 既存の Ruby 製 GPIO gem(`pi_piper`, `rpi_gpio`, `ya_gpio` など)は sysfs や古い wiringPi / 直接レジスタアクセス前提で、多くが長期間メンテナンスされていない。
- Raspberry Pi 5 は GPIO コントローラが RP1 チップに移行し、sysfs ベースの古い方式や、レジスタへ直接アクセスする `pigpio` / 古い `RPi.GPIO` は動作しない。
- 現代的な解法は libgpiod(GPIO character device、uAPI v2)。Python には公式バインディング(`gpiod` package)があるが、Ruby には相当する gem が存在しない。
- libgpiod はカーネル機能であり Pi 5 専用ではなく、Pi 4 / Pi Zero を含む全モデルで動作する。最初から複数世代対応を見据えた設計が可能。
- gpiozero はサーボ駆動時の PWM が CPU 主導のソフトウェア PWM 寄りで、ジッター(細かい震え)が解決しきれない既知の課題がある。SoC のハードウェア PWM ペリフェラルを Linux PWM サブシステム経由で直接叩けば、CPU のスケジューリングに依存しない安定したパルスが出せるはずで、ここを最初から狙いに含める。

## ゴール(フェーズ分け)

- **Phase 1**: Raspberry Pi 5 専用。ffi 経由で libgpiod v2 ABI をラップした GPIO 出力(LED点滅)・入力(ボタン読み取り)に加えて、Linux PWM サブシステム(sysfs)経由のハードウェア PWM 制御を実装し、サーボ駆動でのジッターのない出力を狙う。
- **Phase 2**: gpiochip の自動検出を実装し、Raspberry Pi 4 / Pi Zero (W) にも対応範囲を広げる。
- **Phase 3**: gpiozero に近い高水準 API(LED, Button などのクラス)を、低水準バインディングの上に構築する。

## 対象環境

- OS: Debian Bookworm 世代以降を対象とするが、実際の動作検証は基本的に Trixie 世代で行う。
- ハードウェア: Phase 1 は Raspberry Pi 5 のみ。Phase 2 で Pi 4 / Pi Zero (W) に対応範囲を拡大。
- 依存: libgpiod ランタイム(Bookworm/Trixie でのパッケージ名・バージョンは要確認)、`ffi` gem。
- Ruby: CRuby を前提とする(他実装への対応は当面スコープ外)。

## アーキテクチャ方針

- ターゲットは libgpiod **v2 ABI**(character device, ioctl ベース)。v1 系との互換は当面スコープ外とする。
- レイヤー構成は以下の三層を想定:
  1. **最下層**: `ffi` で libgpiod の C 関数を `attach_function` する層。
  2. **中間層**: Chip / LineRequest などを Ruby らしいオブジェクトでラップする層(Python の `gpiod` package に相当)。
  3. **上位層(Phase 3)**: gpiozero 風の高水準 API(LED, Button など)。現時点では別 gem として切り出す想定だが、最終判断は Phase 1/2 の実装量・粒度を見てから行う。
- Phase 1 では gpiochip のパスを `/dev/gpiochip0` に決め打ちしてよい。Phase 2 でチップの `label`(Pi 5 系は `pinctrl-rp1`、それ以前は `pinctrl-bcm2835` 等)を見て対象チップを自動判定するロジックに置き換える。
- ハードウェア PWM は libgpiod(GPIO character device)とは別の Linux サブシステム(PWM class, `/sys/class/pwm/pwmchipN/`)経由で扱う。`export` / `period` / `duty_cycle` / `enable` といったファイルへの読み書きだけで操作できるため、PWM 部分は `ffi` や ioctl を介さない素のファイル I/O で実装できる見込み。
- ハードウェア PWM の有効化(対象 GPIO を PWM の alt function に切り替える)は起動時の Device Tree overlay 設定(`/boot/firmware/config.txt` への `dtoverlay` 追加など)が前提になり、gem の実行時操作だけでは完結しない。gem 側はオーバーレイが正しく設定されているかの確認・案内までを責務とし、`config.txt` の自動書き換えはスコープ外とする。
- Pi 5 では PWM chip の番号付けが直感的でない(オンボード PWM が `pwmchip0`、RP1 側の PWM が `pwmchip2` になるなど、プローブ順依存で固定でない)ことが分かっているため、GPIO のチップ自動検出と同様に、PWM 側もチップ・チャンネルの自動判定ロジックを用意する。
- Linux カーネル側では PWM 用の chardev ABI(libgpiod 相当の新しい仕組み)が議論・実装が進行中で、将来的にこちらへ移行する可能性がある。現時点(Trixie 世代のカーネル)では sysfs ベースの実装で進め、chardev ABI の動向は継続的に確認する。

## Phase 1 タスク(Raspberry Pi 5 専用)

### GPIO(digital I/O)

1. プロジェクト雛形を作成する(gemspec、`lib/libgpiod_ffi.rb`、ディレクトリ構成)。
2. Trixie 環境に libgpiod のランタイム・開発パッケージが入っていることを確認する(`gpiodetect` 等のCLIツールで動作確認)。
3. libgpiod の最小限の C API(chip open/close、line request、set/get value)を `ffi` で `attach_function` する。
4. `/dev/gpiochip0` を決め打ちで開き、LED 1個を点滅させるサンプルスクリプトを動かす。
5. ボタン入力の読み取り(エッジ検出含む)を動かす。
6. 上記が安定したら、Chip / LineRequest クラスとしてオブジェクト指向ラッパーに整理する。

### ハードウェア PWM

7. Pi 5 でハードウェア PWM が使える GPIO(GPIO12 / 13 / 18 / 19)向けに、必要な `dtoverlay` 設定(`config.txt`)を確認・ドキュメント化する。
8. `/sys/class/pwm/pwmchipN/` 以下の `export` / `period` / `duty_cycle` / `enable` をラップする最小限のクラスを実装する(ffi は使わずファイル I/O のみ)。
9. 環境によって PWM chip の番号付けが変わる問題(オンボード PWM が `pwmchip0`、RP1 側が `pwmchip2` になるケースなど)に対応する自動判定ロジックを実装する。
10. サーボモータを実機で駆動し、gpiozero で報告されているジッターが発生しないことを確認する。

### 共通

11. README とサンプルコード(GPIO・PWM双方)を用意する。

## Phase 2 タスク(Pi 4 / Pi Zero 対応)

1. gpiochip 一覧を取得し、`label` を見て対象チップを自動判定するロジックを実装する。
2. Pi 4 / Pi Zero (W) 実機でカーネルバージョンと libgpiod パッケージのバージョンを確認し、最低要件を確定する。
3. Phase 1 のサンプルが複数ボードで同一コードのまま動くことを確認する。
4. 32bit(armhf、Pi Zero / 旧モデル系)環境でも `ffi` 経由の動的リンクが問題なく動くことを確認する。
5. Pi 4 / Pi Zero でのハードウェア PWM(`dtoverlay` 設定や pwmchip の番号付け)の差異を調査し、Phase 1 の PWM 自動判定ロジックを拡張する。

## Phase 3 タスク(高水準API)

現時点では別 gem(例: `gpiod-zero`)として切り出す想定。最終判断は Phase 1/2 の実装量・粒度を見てから行う。

1. gpiozero のクラス構成(LED, Button, PWMLED など)を参考に、Ruby版での命名・API デザインを検討する。
2. Phase 1/2 の低水準ラッパー(GPIO・PWM 双方)の上に高水準クラスを実装する。
3. 別 gem 切り出しを前提に、`libgpiod-ffi` 側のインターフェースが高水準層から使いやすい形になっているか見直す。

## 未決事項・要確認

- rubygems.org への公開タイミングの厳密な基準(「最低限の入出力が動いてから」の具体的な完了条件)。
- Phase 3 を別 gem に分離する場合の、`libgpiod-ffi` 側との依存関係・バージョニング方針。
- PWM chardev ABI の標準化動向(状況次第で Phase 2 以降に実装方針を見直す可能性あり)。

## リスク

- libgpiod v2 ABI の C の構造体を `ffi` で正しくマッピングする部分が最もハマりやすい(アラインメント、ポインタ、共用体の扱いなど)。
- Pi Zero(初代 / ARMv6)やカーネルが古いイメージでの動作検証が困難な可能性がある。
- libgpiod のパッケージバージョンが Bookworm / Trixie 間で異なる場合、API の差異が出る可能性がある。
- ハードウェア PWM の sysfs インターフェースはボード・カーネルバージョンによって pwmchip の番号付けや必要な `dtoverlay` 設定が変わりやすく、ドキュメント通りに動かないケースが多数報告されている。実機での試行錯誤がそれなりに必要になる前提で見積もる。
- PWM 用の dtoverlay 設定は再起動を要するため、開発・デバッグのイテレーションが GPIO 部分より遅くなりやすい。
