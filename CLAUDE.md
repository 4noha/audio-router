# CLAUDE.md — audio-router 作業ガイド

このファイルは Claude Code がこのリポジトリで作業する際の指針。

> **親ワークスペース**: `~/works/4noha-studio-family/`（東雲はつりの制作・配信ツール群アンブレラ）。ARPS v1 契約は親 `CLAUDE.md` / `README.md` に全体図あり。本リポジトリは **shm の所有・作成側**。

## 目的

macOS 14.4+ 専用の **per-app 音声ルータ／パッチベイ**。
プロセスタップ(`AudioHardwareCreateProcessTap`/`CATapDescription`)とマイクを
**ソース**、4ksplitter / babigoe / 録音ファイルを **シンク**、その間を
**名前付き内部バス**（mono Float32 48kHz 固定）で結ぶ。仮想オーディオ
ドライバ(BlackHole 等)は作らない / 不要。

## アーキテクチャ（依存方向）

```
AudioRouterApp (SwiftUI, @MainActor)
  └─ RouterController          1 行 = source ‐ bus ‐ sink (任意片側可)
      ├─ Edge: TapInEdge / MicInEdge / ShmInEdge        (IN → bus.write)
      ├─ AudioBus               mono Float32 48k リング、複数 Reader 独立カーソル
      ├─ Edge: ShmOutEdge / RecorderOutEdge             (bus.read → OUT)
      └─ StatusReporter         非 @MainActor、独自 DispatchSource queue
                                毎秒 status.json atomic 書出＋routes.json mtime 監視
AudioRouterCore (依存最小)
  ├─ ProcessTapEngine / MicCapture                      Core Audio 入力
  ├─ ShmSender / ShmReader                              ARPS v1 (POSIX shm + CShmCompat)
  ├─ LinearResampler                                    srcRate→48k 連続線形補間
  └─ AudioBus / PCMSender / AudioMonitor 等
CShmCompat (C)                                          shm_open(O_CREAT,mode) 正規 varargs
arps-feed / arps-probe (CLI)                            E2E 用 ARPS 合成書込 / attach 計測
```

- **ロジックは Core**、UI(SwiftUI)・自動化(--apply/--quit-after) は薄い殻。
- **同名 bus を複数行で共有 = fan-out**。バスは単一プロデューサ＋複数
  コンシューマ、各 Reader は独立カーソル。
- 起動時の `routes.json` ロードと、外部書換のホットリロード（reporter の
  mtime ポーリング → reconcile）の 2 経路で経路が組み変わる。

## ビルド / 検証コマンド

```bash
# 通常ビルド（debug）
swift build

# .app 化（リリース + Info.plist + 安定/ad-hoc 署名）
scripts/make_app.sh        # → dist/AudioRouter.app

# 起動（初回に音声捕捉許可）
open dist/AudioRouter.app

# E2E 一気通貫（CORE=必須PASS / INFO=参考）
scripts/e2e/run.sh --build
```

**変更後は必ず E2E 1..4 (CORE) が PASS することを確認する**。項目 5
(データ面)は既知 shm 名の他プロセス汚染で false negative し得るので
参考扱い。真の判定は項目 1 の private 名 plumbing。

## 規約・前提

- 言語: Swift 6.0 / `.macOS(.v14)`、ランタイムは 14.4+ を `#available` で強制。
- バス内部表現は **mono Float32 48kHz 固定**（`AudioBus.rate = 48_000`）。
  入力側の他レートは `LinearResampler` で 48k へ揃えてから write。
- ARPS v1 共有メモリ契約（受信側 = C# / 送信側 = Swift で **byte 一致**必須）:
  - 名前: macOS POSIX shm 名上限 31 文字。`/4ksp.voice3`(枠1 レガシー),
    `/4ksp.voice3.<2..4>`(枠2..4), `/babigoe.in3`(audio-router → babigoe),
    `/babigoe.out3`(babigoe → audio-router), `/babigoe-in.g1.m48.1` /
    `-out.g1.m48.1`(VST デッキ), `/obs.mic3`(.2..4) / `/obs.video3`(.2)
    (audio-router → OBS ほか)。台帳の権威は `docs/arps-shm-spec.md` §5
  - **1 shm = 1 consumer**(readIndex は単一カーソル)。読み手を増やすときは
    同じ bus を別 sink 行へ fan-out して枠を分ける。ライブ字幕
    (yt-translator `serve_engine.py --arps`, 起動は `scripts/yt_subtitles.sh`)
    は `/obs.mic3.2` に attach する運用。供給は本アプリの fan-out 行か
    OBS「AudioRouter SHM Output」フィルタ(OBS 内ソース指定)の**どちらか
    片方**(1 枠 1 書き手、二重書込禁止)
  - ヘッダ 64B: `magic="ARPS"LE(0x53505241)` / `version=1` /
    `sampleRate=48000` / `channels=1` / `capacity=96000` / `ready` /
    `consumerPid` / `writeIndex` / `readIndex`
  - ペイロード: Float32 × capacity の単一リング、再送なし・ロス許容。
- 共有メモリの**作成・所有・破棄**は audio-router(Swift+CShmCompat) が
  全枠を一手に eager-create（OUT エッジ start 時 / 毎 5ms tick で `open()`）。
  C# 受信側(4ksplitter/babigoe)は **attach 専用**、未生成なら 1s ゲートで再試行。
- 永続化先: `~/Library/Application Support/AudioRouter/`
  - `routes.json`（経路、外部書換は mtime ポーリングで reconcile）
  - `status.json`（毎秒 atomic 書出、自動化/ヘッドレス検証の唯一の窓）
- 録音 sink の出力先: `~/Music/AudioRouter/rec-<yyyyMMdd-HHmmss>.wav`
  （PCM16 mono 48k）。Music は TCC 保護対象外で非サンドボックスでも
  許可ダイアログが出ない。
- 自動化引数（`AudioRouterApp.handleAutomationArgs`）:
  `--apply <path>` でアプリ起動前に `routes.json` を置換 /
  `--quit-after <sec>` で N 秒後に自動終了。E2E と Claude のオペ自動化に使う。

## 落とし穴

- **macOS の shm パーミッションは `shm_open(O_CREAT, mode)` の `mode` 引数
  でしか決まらない**（`fchmod` は EINVAL で不可）。Swift の `dlsym` 固定
  引数だと C 可変長引数の arm64 ABI でゴミ化するため、`CShmCompat` の
  正規 varargs ラッパ(`cshm_open_create`)で 0666 生成すること。
- **shm_unlink しない**。unlink すると attach 済みの書き手(babigoe 等)が
  orphan を掴み続け音が来なくなる。名前付き shm を安定した待ち合わせ点
  として再利用し、再起動時はヘッダ再初期化のみ行う。
- ARPS の `magic` は **"ARPS" LE = 0x53505241**。`Arp1ShmWriter` の旧
  バイト並びと混同しない。`Sender` と `Reader` の両方で magic 一致確認 +
  不一致なら attach 拒否する設計を崩さない。
- **ad-hoc 署名(`codesign -s -`)は再ビルド毎に cdhash が変わり TCC マイク
  許可が無効化**される（mic=0 で無音）。`scripts/make_app.sh` は安定
  codesign ID があれば自動でそれを使う。ad-hoc 強制時はビルド毎に
  「設定→プライバシ→マイク」で再付与必要。
- **モニタ ON で二重再生**: アプリ音をタップ + システム出力に流すと OS の
  通常再生と二重に鳴る。`muteSource` フラグでタップ元アプリ側の出力を
  ミュートする（既存 fix、外さない）。
- **起動時に recorder を auto-start しない**。`routes.json` で
  `enabled:true` のままでも `sink == .recorder` の行は起動時に `enabled=false`
  に落とす（不意の録音 / ディスク浪費の防止、明示トグルでのみ開始）。
- **OUT エッジの流量判定は `consumedFrames`(受信側 readIndex)＋実信号
  レベル**。送信側 writeIndex でカウントすると 4ksplitter 停止時にも
  ♻ が回り続けて誤検知する。
- **ContentView の `RouteRow` decode は明示 `init(from:)` で全キー
  `decodeIfPresent ?? 既定値`**。旧 `routes.json`(splitterSlot 等の新キー
  未保存)を全 throw させない後方互換が前提。エンコードは合成で OK。
- **`StatusReporter` は MainActor 非依存の自前 DispatchSource queue で
  完結**。bare binary / ヘッドレス自動化では Swift Concurrency main
  executor が枯渇するので、`Task{@MainActor}` で reconcile を回そうと
  しない（GCD main + `assumeIsolated` を使う）。
- **App Nap で背面停止しない**ように `ProcessInfo.beginActivity` で
  `userInitiated | idleSystemSleepDisabled` を取り続ける（非フロント /
  ヘッドレスでも pump 継続）。
- パスに**非 ASCII ハイフンを使わない**（隣接 `babigoe‐kai` ハマり済）。

## 変更時のチェックリスト

1. ロジックは `AudioRouterCore` に。UI / 自動化は薄い殻のまま。
2. ARPS 契約に触る変更は **5 repo (audio-router / 4ksplitter / babigoe-kai / pan-pan / obs-plugins/obs-audio-router-shm) 同時** で byte 一致を保つ。byte 契約・名前文法・現行 shm 名台帳・拡張ルールの権威ドキュメントは **[`docs/arps-shm-spec.md`](./docs/arps-shm-spec.md)**。スロット拡張の段階的計画は [`docs/multi-voice-slots-design.md`](./docs/multi-voice-slots-design.md)。
3. `scripts/e2e/run.sh --build` の CORE(1..4)が PASS することを確認（特に shm/制御面/ホットリロード/babigoe ヘッドレス）。
4. `routes.json` キーを足したら `RouteRow.init(from:)` に `decodeIfPresent` を追加（既存ユーザの経路を消さない）。
5. UI 変更は `open dist/AudioRouter.app` で起動確認。`status.json` の `rows[]` が UI と一致することを確認。
6. README.md の「概要・shm 経路・自動化引数」と矛盾しないよう更新。
