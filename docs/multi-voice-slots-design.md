# 設計: マルチ音声スロット（最大4枠の独立 voice → 4ksplitter 複数モデル）

ステータス: **設計のみ（未実装）**。ユーザ確認待ち。
作成: 2026-05-18。対象 repo: `audio-router`(Swift) / `4ksplitter_`(Unity C#)。
非対象: `babigoe-kai`（変更不要・後述）。

## 1. ゴールと方針

- ゴール: **4ksplitter で複数モデル（当面2体、最大4体）を、それぞれ独立した音声入力でリップシンク駆動**。
- 方針: ARPS を 4ch インターリーブにはしない。**mono ARPS v1 のまま「名前付き shm チャンネルを増やす」**。
  - 理由: ARPS v1 契約は 3 repo byte 一致で実機検証済み。契約バージョンを上げると 3 repo 同時改修＋回帰リスク。チャンネルを増やすだけなら契約不変・既存経路無傷。
- スロット = **独立した mono ARPS v1 リング**（4ch バッファではない）。

### shm 名スキーム（確定）— 「名付けで仕様を分ける」

**原則**: 名前＝スペック識別子（namespace / intent / 枠）、ヘッダ＝byte 契約の
権威。名前だけに依存せず、attach 時にヘッダ `magic`/`version`/`channels` を
必ず検証して安全網とする（名前再利用・配線バグの保険）。

1. 名前で intent と枠を分離 → mono 受信側が stereo リングを物理的に誤
   attach 不能（名前が違えば交差不能）。
2. ヘッダで byte 契約を検証 → 名前一致でもヘッダ不一致なら attach 拒否。
3. **名前↔スペック台帳を1箇所**に定義し 3 repo byte 一致でミラー
   （名前＝セレクタ、台帳/ヘッダ＝スペック本体）。
4. レガシー名は文法外として恒久 grandfather（リネームは 3 repo 同時
   改修が必要なので避ける）。

**名前文法（macOS POSIX shm 名上限 = 31 文字内）**

| 種別 | 名前 | 意味（台帳） |
|---|---|---|
| レガシー(grandfather) | `/4ksp.voice3` | ARPS v1 / mono48k / 枠1。literal 据置・改名不可 |
| 同系・枠 | `/4ksp.voice3.2` … `.4` | 同契約(v1/mono48k)、枠2..4 |
| 新スペック(将来) | `/4ksp.<gen>.<fmt>.<slot>` | 例 `/4ksp.g2.st.1` = ARPSv2/stereo48k/枠1 |

- `<gen>` = `g1`,`g2`…（ヘッダ `version` に対応）
- `<fmt>` = `m`(mono48k) / `st`(stereo48k)（ヘッダ `channels` に対応）
- `<slot>` = `1`..`9`
- 文字数: `/4ksp.voice3.4`=14、`/4ksp.g1.m.2`=15、`/4ksp.g2.st.1`=13。全て安全。

- 現フェーズの 4 枠は全て `ARPS v1 / mono48k`（64Bヘッダ + Float32[96000]
  mono, totalBytes=384064, `channels`=1）で**完全に同一レイアウト**。
- 作成・所有は従来どおり **audio-router(Swift, CShmCompat) が全枠を一手に
  eager-create**。C#(4ksplitter)は attach 専用（O_RDWR 2引数, ABI 安全）＋
  **attach 時ヘッダ検証必須**（magic/version/channels が台帳と一致しなければ拒否）。

## 2. フェーズ分割

- **Phase 1: audio-router 側（低リスク・単独で出荷可・後方互換）** — ルートの 4ksplitter sink にモデル枠 1..4 を持たせ、枠ごとに別 shm へ送出。Unity 無改修でも枠1は従来動作。
- **Phase 2: 4ksplitter 側（大規模・単一モデル前提の解体）** — 受信のマルチ shm 化＋マルチモデル化＋複数レンダリング。Phase 1 とは独立に進められる（Phase 1 だけ先に本番投入可能）。

---

## 3. Phase 1 — audio-router 側 詳細

### 3.1 `Sources/AudioRouterApp/RouteEdge.swift`

`RouteRow` に枠番号を追加:

```swift
var splitterSlot: Int = 1   // 1...4。sink == .splitter のときのみ意味を持つ
```

**Codable 移行の落とし穴（重要）**: Swift の自動合成 `Decodable` は **キー欠落で throw**。既存 `routes.json` には `splitterSlot` が無いため、そのままだと全ルート読み込み失敗。対策＝`RouteRow` に明示 `init(from:)` を実装し、全キー `decodeIfPresent(...) ?? 既定値` で前後方互換にする（`splitterSlot` は `?? 1`）。`encode` は合成のままで可。

表示への反映:

```swift
var displaySink: String? {
    guard let s = sink else { return nil }
    if s == .splitter && splitterSlot > 1 { return "4ksplitter#\(splitterSlot)" }
    return s.label
}
```

（`oneLine` は `displaySink` 経由なので自動反映。枠1は従来表示「4ksplitter」のまま＝既存ルートの見た目不変。）

### 3.2 `Sources/AudioRouterCore/ShmSender.swift`

スロット→名前のヘルパを追加（枠1=レガシー名）:

```swift
public static func splitterName(slot: Int) -> String {
    let s = max(1, min(4, slot))
    return s == 1 ? nameToSplitter : "\(nameToSplitter).\(s)"
}
```

`nameToSplitter`/`nameBabigoeIn` は据置。`ShmSender(srcSampleRate:name:)` は既に name 可変なので**本体改修不要**。eager-create / consumerPid / `kill(pid,0)` / 1s ゲートはすべて name 単位で正しく動く（枠ごとに独立した受信側 PID 監視・🚫 判定）。

### 3.3 `Sources/AudioRouterApp/RouterController.swift`

`activate()` の splitter 分岐のみ変更:

```swift
case .splitter:
    let s = ShmOutEdge(shmName: ShmSender.splitterName(slot: r.splitterSlot), bus: b)
    s.start(); outE = s
```

他は不変（`flowByRow`/`sinkDown`/診断は ShmOutEdge 単位なので枠ごとに独立して機能）。

### 3.4 `Sources/AudioRouterApp/ContentView.swift`（`RouteEditorView`）

sink Picker の直後、`snk == .splitter` のときだけ枠選択を表示:

```swift
if snk == .splitter {
    Picker("モデル枠", selection: $splitterSlot) {
        ForEach(1...4, id: \.self) { Text("モデル \($0)").tag($0) }
    }
}
```

`@State private var splitterSlot = 1` を追加、`onAppear` で `original.splitterSlot` 復元、保存時 `r.splitterSlot = splitterSlot`。行表示は `displaySink` が自動で「4ksplitter#2」を出す。

### 3.5 Phase 1 の特性

- ARPS 契約不変、`babigoe-kai` 無関係（変更ゼロ）。
- 枠1は名前据置＝**現行 4ksplitter / 既存 routes.json と完全後方互換**。
- 単体で本番投入可（Unity 改修前でも、枠1で従来どおり1モデル駆動。枠2..4 は受信側が未対応なら送出が読まれず無害＝`sinkDown`/🚫 で可視化）。
- 検証: `swift build` + `make_app.sh`。複数ルートを別枠に割り当て、各 ShmOutEdge が別 shm を eager-create することを diag で確認。

---

## 4. Phase 2 — 4ksplitter 側 詳細（大規模・要慎重）

現状（Explore 実地調査で確定）:

| 箇所 | 現状 | 問題 |
|---|---|---|
| `Assets/VRig/VoiceShmReceiver.cs:19` | `private const string ShmName = "/4ksp.voice3"` | shm 名ハードコード・per-instance 不可 |
| `Assets/VRig/VoiceLipSync.cs:20` | `public static VoiceLipSync Instance`（シングルトン） | 1 インスタンスのみ・`_shmRx` 単一 |
| `VoiceLipSync.MouthVrm()` (~289) | `HolisticSolution.Instance.Model.VrmRoot` 固定 | 単一モデルにしか口を当てられない |
| `Holistic/HolisticSolution.cs:113` | 単一 `model`、`SetModel()` は破棄→差替 | モデル枠の概念なし |
| `ModelControlController` / SplittedController | SFX スロットにモデル1体を割当 | 同時1体のみ |
| `VRigBootstrap` (~324) | 単一 `ModelCamera`(RenderTexture) | 1モデルしか描画されない |
| `VRigConfig` / `AppSettings` | 全グローバル | per-slot 設定なし |

### 4.1 サブステップ（依存順）

**2a. `VoiceShmReceiver` パラメータ化**
- `private const string ShmName` → `private string _shmName`、コンストラクタ引数 `VoiceShmReceiver(string shmName = "/4ksp.voice3")`。
- 既定値を従来名にして単一モデル経路は無改修動作。`OffConsumerPid`(=24) への自 PID 書込はそのまま（枠ごとに独立 PID 公開＝audio-router 側 `kill(pid,0)` が枠別に効く）。

**2b. `VoiceLipSync` 脱シングルトン → チャンネル化**
- `VoiceLipSync`(global) → **`VoiceLipSyncManager`(1個)** + **`VoiceLipChannel`(最大4)**。
- `VoiceLipChannel` = { `VoiceShmReceiver`(枠別 shm 名), uLipSync リグ(AudioSource+uLipSync), 対象モデル参照, profile/gain/smoothing(枠別) }。
- `OnShmPcmRead` / `Update`(口形状適用) を **チャンネル単位**に。`MouthVrm()` を「シングルトン Holistic → 当該チャンネルの対象モデル」へ変更。
- 既存 `SetMic()/SetShmSource()` 互換 API は「枠1チャンネル操作」に委譲（呼び出し側＝WebcamController 影響最小化）。

**2c. `HolisticSolution` マルチモデル化**
- 単一 `model` → `Dictionary<int,SceneModel>`（または長さ4配列）。`SetModel(slot, vrm)` / `GetModel(slot)`。slot 0/1 = レガシー経路（既存 `Model` プロパティは枠1を返す互換シム）。
- ランドマーク→ポーズ駆動部が `Model` 単一前提の箇所を全て slot 対応に（要全 caller 調査：RigAnimator/VRMAnimator 連携）。**ここが最大の波及面**。

**2d. 複数レンダリング**
- モデル枠ごとに `ModelCamera`+`RenderTexture`+SFX 配置スロット。`ModelControlController`/`SplittedController` の `Allocate/ReleaseModelSlot` を slot 引数化。SFXTextureShader の `_MirrorX` 等は枠別マテリアルインスタンス。
- レイアウト（Modulation 画面）に2体目以降の表示枠を追加（UiKit.Layout 編集。`UiKit.Layout.` 完全修飾必須）。

**2e. 設定・UI**
- `VRigConfig`/`AppSettings` に per-slot 配列：`voiceShmSlot[i]`(=1..4)、`voiceProfileName[i]`、`voiceVolumeGain[i]`、on/off、入力ソース名。
- AppSettings(JSON, persistentDataPath) の CaptureTo/ApplyFrom を配列対応（既存単一キーは枠1へマイグレーション）。
- .vrm D&D ロード（VRigBootstrap.LoadVrmFromPath/ApplyLoadedVrm）を「どの枠へロードするか」選択可能に。

### 4.2 リスクと緩和

- **回帰リスク（実機検証済み VRig パイプライン）**: 既定経路（枠1のみ・shm 名据置・単一モデル）を **挙動 byte 不変**に保つ。マルチモデルは **フィーチャーフラグ（VRigConfig）** で opt-in。1モデル時は現行コードパスと等価。
- **git ステージング制約（厳守）**: 4ksplitter は **VRig 関連ファイルのみ選択コミット**。`CropMaterial.mat`/`Mobile_RPAsset.asset`/`EditorSettings.asset`/`_Recovery/`/`Editor.meta` は**絶対にステージしない**。
- **段階投入**: 2a→2b は単一モデルのまま緑化可能（チャンネル数=1）。2c/2d が本丸。各サブステップで Unity `check_compile_errors` 緑を確認しつつ進む。
- **パフォーマンス**: ModelCamera/RT がモデル数ぶん増える。Mobile_RPAsset は触らない制約があるため、RT 解像度・更新レートは枠別設定で抑制可能に。

## 5. スコープ外（記録のみ）

- **動画ソースのステレオ(2ch)保持**: ユーザ要望あるが現用途なし → 本設計では非対応。必要時は §1 名前文法に従い **ARPS v2(ch=2)** を新名 `/4ksp.g2.st.<slot>` で**並存**（v1 と別名なので mono 経路と物理的に非交差、3 repo 台帳 byte 一致で同時対応）。本設計のスロット方式とは直交し、名付けで仕様分離できる。
- `babigoe-kai`: 変更不要。babigoe 経路は従来どおり枠1（または audio-router バス経由で任意枠）へ。

## 6. 着手順の推奨

1. **Phase 1 を実装・実機確認・3 repo 非依存で audio-router 単独 push**（低リスク、すぐ価値）。
2. Phase 2 を 2a→2b（単一モデルのまま緑）→ 2c → 2d → 2e の順。各段で Unity コンパイル緑＋単一モデル回帰確認。
3. 2 体実機リップシンク確認後、選択コミット（VRig ファイルのみ）。

— 以上、実装は本ドキュメント合意後に着手。
