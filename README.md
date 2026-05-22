# audio-router

macOS 14.4+ 専用の **per-app 音声ルータ／パッチベイ**（Swift + SwiftUI / スタンドアロン）。

入力（VLC 等のアプリ音 / マイク / babigoe 出力）と出力（4ksplitter / babigoe 入力 /
ファイル録音）を、**名前付き内部バス**(mono Float32 48kHz)で自由に
組み替える。UI(FROM/TO リスト・ON/OFF トグル・波形)はすべて本アプリ側。
仮想オーディオドライバ(BlackHole/AudioServerPlugIn 等)は**作らない / 不要**。

per-app 捕捉は Apple Core Audio の **プロセスタップ API**
（`AudioHardwareCreateProcessTap` / `CATapDescription`, macOS 14.4+）。
「VLC だけ」を対象にでき、他アプリ/システム音は混ざらない。VLC 側の
設定は変更不要（出力先を触らない）。

## パッチベイ・モデル

```
SOURCE                        BUS (named, mono f32 48k)             SINK
  appTap (VLC 等)  ─┐                                           ┌─→  splitter (slot 1..4)
  mic              ─┼─→ bus1 ─┬─→ ...                          │     /4ksp.voice3, .2..4
  babigoeOut       ─┘         ├─→ bus2 (同名 bus を別行で fan-out)┼─→  babigoeIn /babigoe.in3
                              │                                  └─→  recorder
                                                                       ~/Music/AudioRouter/*.wav
```

- 1 行 = `source ‐ bus ‐ sink`。source / sink のどちらかが nil でも可
  （受け取らずに録るだけ・別バスへ流すだけ）。
- 同じバス名を複数行で共有すると自動的に **fan-out**（タップ 1 つ →
  4ksplitter＋録音＋モニタ同時、など）。
- 内部バスは mono Float32 48kHz 固定。入力レートが違えば線形補間で揃える。

### ソース / シンク一覧

| 種別   | 名前          | 内容 |
|--------|---------------|------|
| source | `appTap`      | 指定アプリの出力を Process Tap API で捕捉 |
| source | `mic`         | 入力デバイス（既定 or UID 指定） |
| source | `babigoeOut`  | `/babigoe.out3` を attach（babigoe 処理済を回収） |
| sink   | `splitter`    | `/4ksp.voice3`(枠1) / `/4ksp.voice3.<2..4>` へ送出（4ksplitter リップシンク） |
| sink   | `babigoeIn`   | `/babigoe.in3` へ送出（babigoe へマイク供給） |
| sink   | `recorder`    | `~/Music/AudioRouter/rec-<ts>.wav`（PCM16 mono 48k） |

`recorder` は安全側設計として **起動時に自動開始しない**（明示トグル ON
のみ録音、不意の録音とディスク浪費を防止）。

## ARPS v1 共有メモリ契約（外部 repo との byte 一致仕様）

audio-router / 4ksplitter / babigoe-kai の 3 repo で **byte 一致**して
いる固定契約。本リポは「**全 shm の作成・所有を一手に担う**」側で、
C# 受信側は attach 専用。

- 名前: macOS POSIX shm 上限 **31 文字**内で `intent.<gen>.<fmt>.<slot>`
  規約（詳細 `docs/multi-voice-slots-design.md`）。現フェーズで稼働中:

  | 名前 | 方向 / 用途 | レイアウト |
  |---|---|---|
  | `/4ksp.voice3`         | audio-router → 4ksplitter (枠1, レガシー grandfather) | ARPS v1 / mono48k |
  | `/4ksp.voice3.<2..4>`  | 同上、枠2..4（複数モデル独立リップシンク）             | ARPS v1 / mono48k |
  | `/babigoe.in3`         | audio-router → babigoe (マイク供給)                    | ARPS v1 / mono48k |
  | `/babigoe.out3`        | babigoe → audio-router (DSP 後を回収)                  | ARPS v1 / mono48k |

- ヘッダ **64 byte**（リトルエンディアン）:

  | offset | size | フィールド |
  |--------|------|------------|
  | 0..3   | 4    | magic = ASCII `"ARPS"` LE (0x53505241) |
  | 4..7   | 4    | version = 1 |
  | 8..11  | 4    | sampleRate = 48000 |
  | 12..15 | 4    | channels = 1 |
  | 16..19 | 4    | capacity = 96000 frames (= 2 秒) |
  | 20..23 | 4    | ready (初期化完了で 1) |
  | 24..27 | 4    | consumerPid (受信側が公開) |
  | 32..39 | 8    | writeIndex (累積、ラップ可) |
  | 40..47 | 8    | readIndex  (累積、ラップ可) |

- ペイロード: Float32 × 96000 の単一リング、再送なし・ロス許容
  （リップシンク用途のため連続性 > 完全性）。
- 作成・破棄: audio-router(Swift+`CShmCompat`) のみ。`shm_open(O_CREAT, 0666)`
  を C 可変長引数で正規に呼ぶ（`fchmod` 不可、Swift `dlsym` 固定引数で
  arm64 ABI ゴミ化を避ける）。`shm_unlink` はしない（attach 済み書き手の
  orphan 化回避、再起動時はヘッダ再初期化のみ）。
- 受信側生存: `consumerPid` を `kill(pid, 0)` で確認、起動 6 秒経っても
  alive=false なら sink に 🚫 表示。

## ビルド

```bash
cd ~/works/audio-router

# 通常ビルド
swift build

# .app 化 + 署名
scripts/make_app.sh        # → dist/AudioRouter.app
open dist/AudioRouter.app
```

### 署名と権限

- 他プロセス音声タップは macOS の許可ダイアログが必要。Info.plist の
  `NSAudioCaptureUsageDescription` / `NSMicrophoneUsageDescription` と
  `com.apple.security.device.audio-input` entitlement は `make_app.sh`
  が自動付与。
- `scripts/make_app.sh` は **安定 codesign ID があれば優先**して署名する。
  **ad-hoc(`-`) 署名は再ビルド毎に cdhash が変わり、TCC のマイク許可が
  リセットされる**（mic=0 で無音）。ad-hoc しか無い環境ではビルド毎に
  「設定 → プライバシ → マイク」で再付与すること。

## 自動化 / オペレーション

UI 操作なしのヘッドレス検証・Claude オペ用に、起動引数と機械可読
ステータスを備える。

```bash
# 指定 routes.json で起動し N 秒後に終了（E2E ハーネス向け）
dist/AudioRouter.app/Contents/MacOS/AudioRouter \
  --apply /path/to/routes.json --quit-after 12
```

- `--apply <path>` — アプリ起動前に `~/Library/Application Support/AudioRouter/routes.json` を上書き
- `--quit-after <sec>` — 指定秒後に `NSApplication.terminate`
- `routes.json` の**外部書換はホットリロード**される（`StatusReporter` の
  1 秒 mtime ポーリングが atomic/in-place 問わず検出 → reconcile）。
- `status.json`（同ディレクトリ）に**毎秒 atomic** で稼働状況を吐く:
  `rows[*]` に `oneLine` / `enabled` / `active` / `inFlow` / `outFlow` /
  `sinkDown` / `inFrames` / `outFrames` / `status`。ヘッドレス検証の唯一の窓。
- App Nap 抑止: `ProcessInfo.beginActivity(userInitiated | idleSystemSleepDisabled)`
  を起動中保持（背面 / bare 実行でもルーティング継続）。

### E2E 検証ハーネス

```bash
scripts/e2e/run.sh --build
```

CORE(必須PASS)= ① arps プラミング(arps-feed→arps-probe, private 名・
汚染非依存) / ② AudioRouter `--apply` 制御面 / ③ `routes.json` ホット
リロード / ④ babigoe ヘッドレス WAV 出力。INFO= ⑤ AudioRouter データ面
（既知 shm 名は他プロセス汚染で false negative し得るので参考）。

## 連携対象

- **4ksplitter** (Unity / C#)
  - audio-router の `splitter` sink を attach 受信、マルチモデル時は枠
    1..4 の各 shm を個別 attach。設計 `docs/multi-voice-slots-design.md`。
- **babigoe-kai** (.NET, バ美声 macOS 移植)
  - audio-router の `babigoeIn` sink から mic を貰い、DSP 後を
    `/babigoe.out3` へ書く → audio-router の `babigoeOut` source が回収。
- **pan-pan** (.NET, 効果音抽出 Phase1)
  - Phase1Engine は `/4ksp.voice3` または `/babigoe.out3` を選択して
    ARPS v1 で送出。audio-router 側は `babigoeOut` source としてその
    まま回収可（同契約・同レイアウト）。

## ディレクトリ

```
Sources/
  AudioRouterCore/        DSP・Core Audio・ARPS shm I/O（依存最小）
    AudioBus.swift          mono f32 48k リング・複数 Reader 独立カーソル
    ProcessTapEngine.swift  Process Tap API
    MicCapture.swift        マイク捕捉
    ShmSender / ShmReader   ARPS v1 (CShmCompat 経由)
    LinearResampler.swift   srcRate→48k 連続線形補間
  AudioRouterApp/         SwiftUI + RouterController（薄い殻）
    RouteEdge.swift         RouteRow / SourceKind / SinkKind
    EdgeEngines.swift       Tap/Mic/ShmIn/ShmOut/Recorder の各エッジ
    RouterController.swift  パッチベイ本体・status.json・hot-reload
    ContentView.swift       UI（Patchbay / Activity / Maintenance）
  CShmCompat/             shm_open(O_CREAT, mode) 正規 varargs(C)
  arps-feed/              指定 shm に正弦波を書き続ける検証 CLI
  arps-probe/             指定 shm を attach しヘッダ/流量を JSON 出力
scripts/
  make_app.sh             .app ビルド + 署名
  e2e/run.sh              一気通貫 E2E（CORE PASS 必須）
docs/
  multi-voice-slots-design.md   マルチ枠（最大4）の名前空間設計
```

## 出所 / ライセンス

- Process Tap API 利用は Apple 公開 API のみ。
- ARPS v1 共有メモリ契約は audio-router / 4ksplitter / babigoe-kai の
  3 repo で byte 一致して維持。
- 個人利用前提（再配布・公開は不可）。
