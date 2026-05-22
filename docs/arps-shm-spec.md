# ARPS shm 共有メモリ仕様 — 配信側 5 リポジトリ共通契約

ステータス: **権威ドキュメント (normative)**。本契約は配信側 5 リポジトリ
(`audio-router` / `4ksplitter_` / `babigoe-kai` / `pan-pan` /
`obs-plugins/obs-audio-router-shm`) で **バイト一致**で運用される。

> 配置: `audio-router/docs/arps-shm-spec.md`
> 関連: `multi-voice-slots-design.md`（スロット拡張の段階的実装計画）

レイアウト変更は 5 repo 同時改修＋実機回帰必須。**名前の追加（既存名据置）は
本ドキュメントの台帳に追記すれば回帰最小**で運用できる（後述）。

---

## 1. 設計原則

**名前＝スペック識別子 / ヘッダ＝byte 契約の権威**

1. **名前で intent と枠を分離** — mono 受信側が stereo リングを物理的に誤
   attach 不能（名前が違えば交差不能）。
2. **ヘッダで byte 契約を検証** — 名前一致でもヘッダ不一致なら attach 拒否。
3. **名前↔スペック台帳を本ドキュメントに集約** — 5 repo でこのファイルを
   ミラーリングしてバイト一致。台帳は §5。
4. **レガシー名は文法外として恒久 grandfather** — リネームは 5 repo 同時
   改修コストが高いので避ける。新規枠のみ §3 の新文法で命名する。

**所有・接続**

- **`audio-router` (Swift, `ShmSender` / `ShmReader`) が全 shm の所有・eager-create 者**。
  受信側 (Unity/C# / .NET / OBS) は **attach 専用**、`O_CREAT` も `shm_unlink` も**禁止**。
- `shm_unlink` すると attach 中の他プロセスが orphan を掴み続けて音が止まる
  (POSIX shm の挙動。再 mount しないと復旧しない)。
- 受信側生存確認は ヘッダ内 `consumerPid` フィールドを受信側が自 PID で書き、
  audio-router 側が `kill(pid, 0)` で監視する。

---

## 2. byte 契約 (ARPS v1)

リトルエンディアン固定。すべて C プリミティブ整列。

```
offset  type      field         value / 意味
------  --------  ------------  ----------------------------------------
   0    u32       magic         0x53505241  // "ARPS" LE
   4    u32       version       1           // 本契約 = v1
   8    u32       sampleRate    48000       // 固定 48k (writer がリサンプル済)
  12    u32       channels      1           // v1 は mono
  16    u32       capacity      96000       // frames (= 2 秒 @ 48k)
  20    u32       ready         0 / 1       // 受信側が初期化完了で 1 にする
  24    i32       consumerPid   受信側 PID  // audio-router が kill(pid,0) で生存監視
  28    u32       reserved
  32    i64       writeIndex    累積書込フレーム数 (atomic, writer 更新)
  40    i64       readIndex     累積読出フレーム数 (atomic, reader 更新)
  48    u8[16]    pad           ヘッダを 64B 境界に揃えるパディング
  ----
  64    float32[capacity]       リング本体 (mono インターリーブなし)
  ----
  totalBytes = 64 + capacity * 4 = 64 + 96000 * 4 = 384064
```

**attach 時の検証 (必須)**

```
ok = magic == 0x53505241
  && version == 1
  && channels == 1
  && capacity == 96000
  && (ready == 1 || writer 側で待機可)
```

`ok == false` の場合 attach を拒否。名前再利用や配線バグの保険。

**書込・読出**

- 物理: 64B ヘッダ + `float32[96000]` リング (8byte境界揃え不要、Float32 4byte 単位)
- writer は `writeIndex` を atomic 増分しつつリングへ overwrite (capacity を超える追記は環状に重ね書き)
- reader は前回までの `readIndex` から `writeIndex` までを読み、`readIndex` を進める
- ロス許容 (リアルタイム配信用、再送なし)。受信側が遅延すると古いフレームは上書きで失う

---

## 3. 名前文法

macOS POSIX shm 名上限 = **31 文字**以内。Linux も 254 文字なので 31 字制約を守れば
両 OS で安全。先頭 `/` 必須 (POSIX shm 規約)。

### 3.1 レガシー名 (grandfather・改名不可)

| 名前 | 意味 | データ向き | 所有 |
|---|---|---|---|
| `/4ksp.voice3` | ARPS v1 mono48k / 4ksplitter 枠1 受信用 | audio-router → 4ksplitter | audio-router が create |
| `/babigoe.in3`  | ARPS v1 mono48k / babigoe 入力 (mic 供給) | audio-router → babigoe   | audio-router が create |
| `/babigoe.out3` | ARPS v1 mono48k / babigoe 出力 (変換後回収) | babigoe → audio-router   | audio-router が create |

接尾辞の `3` は **「ARPS v1 / mono48k / 64Bヘッダ」レイアウトを示すフォーマット世代マーカ**
であり、チャンネル番号ではない。チャンネル番号と誤解しがちなので新規名では使わない。

### 3.2 新文法 (生成・stereo・高サンプルレート対応)

```
/<namespace>.<gen>.<fmt>.<slot>
```

| トークン | 値 | 意味 |
|---|---|---|
| `<namespace>` | `4ksp` / `babigoe-in` / `babigoe-out` / 任意 | アプリ/モジュール識別子。**双方向チャンネル (babigoe 等) は `-in` / `-out` 接尾辞で方向を分離**する |
| `<gen>` | `g1`, `g2`, ... | ARPS のメジャー世代 (= ヘッダ `version`) |
| `<fmt>` | プロファイル ID (§3.4 表) | チャンネル数とサンプルレートの組合せ |
| `<slot>` | `1` .. `9` | チャンネル枠番号 |

**方向の扱い**: 単方向 (`4ksp` = audio-router→4ksplitter のみ) は namespace に方向を
含めない。双方向 (babigoe = mic 入力 + 変換音出力) は **異なる namespace** にして
シンメトリックに扱う。例: `babigoe-in` (router→babigoe) と `babigoe-out` (babigoe→router)。
これにより読み手/書き手の役割が名前から自明、混線も起きない。

例:

| 名前 | 文字数 | 意味 |
|---|---|---|
| `/4ksp.g1.m48.1` | 15 | ARPSv1/mono48k/枠1 (= 将来 `/4ksp.voice3` 相当・新規系で使う場合の正式名) |
| `/4ksp.g1.m48.2` | 15 | ARPSv1/mono48k/枠2 |
| `/4ksp.g1.st48.1` | 16 | ARPSv1/stereo48k/枠1 |
| `/4ksp.g1.st96.1` | 16 | ARPSv1/stereo96k/枠1 |
| `/babigoe-in.g1.m48.1` | 21 | babigoe 入力枠1 (= 例: VST デッキ用、§3.1 レガシー `/babigoe.in3` の隣) |
| `/babigoe-out.g1.m48.1` | 22 | babigoe 出力枠1 (= 同上、対の出力) |

**重要**: `<gen>` (= プロトコル世代 = ヘッダ format) と `<fmt>` (= 音質プロファイル) は
直交する。プロファイルだけ増やす分には byte 契約は v1 のまま（capacity 計算式と
ヘッダの sampleRate / channels が変わるだけで、ヘッダ構造 §2 は不変）。世代を上げる
のは「ヘッダ構造自体を変える」ような契約レベルの破壊的変更時のみ。

### 3.3 レガシー名へのスロット接尾辞 (移行措置)

レガシー名を保ちつつ枠を増やす場合の便法。**新規名は §3.2 の文法を使い、§3.3 は
既存ファミリ拡張時の限定運用**とする。

| 名前 | 意味 |
|---|---|
| `/4ksp.voice3.2` ... `.4` | レガシー `/4ksp.voice3` と同契約 (v1/m48) で枠 2..4 |
| `/babigoe.in3.2` ... `.4`  | (実装稼働) babigoe 入力 ch2..4 |
| `/babigoe.out3.2` ... `.4` | (実装稼働) babigoe 出力 ch2..4 |

### 3.4 音質プロファイル台帳 (`<fmt>`)

`<fmt>` トークン → byte 契約パラメータ。**capacity は SR * 2 秒固定**（ウォール
クロック 2 秒のリング容量を保つ）。

| `<fmt>` | channels | sampleRate (Hz) | capacity (frames) | totalBytes | 用途 |
|---|---|---|---|---|---|
| `m48`  | 1 | 48000  | 96000  | 384064  | ✅ 既定。声・LipSync (現行 ARPS v1) |
| `m44`  | 1 | 44100  | 88200  | 352864  | 📦 旧素材互換用 |
| `m96`  | 1 | 96000  | 192000 | 768064  | 📦 高音質モノラル収録 |
| `st48` | 2 | 48000  | 96000  | 768064  | 📦 ステレオ素材（動画音、楽器） |
| `st44` | 2 | 44100  | 88200  | 705664  | 📦 CD 規格ステレオ |
| `st96` | 2 | 96000  | 192000 | 1536064 | 📦 高音質ステレオ |

**totalBytes 計算**: `headerBytes (64) + capacity * 4 * channels` (Float32 = 4byte)。
ステレオはインターリーブ (`L R L R ...`) で書く。

**ヘッダ §2 検証拡張**: attach 時、検証値は **名前から導出されるプロファイル** を
基準とする (固定 48k/1ch ではない)：

```
profile = name の <fmt> から §3.4 表で参照
ok = magic    == 0x53505241
  && version  == 1
  && channels == profile.channels
  && sampleRate == profile.sampleRate
  && capacity == profile.capacity
```

レガシー名 (`/4ksp.voice3` / `/babigoe.in3` / `/babigoe.out3` および `.<n>` 接尾辞)
は **`<fmt>=m48` 暗黙適用**（既存実装と byte 互換）。

**追加プロファイルの実装手順** (例: `st48` を本番投入):

1. 本ドキュメント §5 台帳に新名 (例 `/babigoe.g1.st48.1`) を追記、ステータス 🛠
2. `audio-router` に対応する eager-create と source/sink を追加（capacity 計算は
   profile から）
3. 受信側 (babigoe-kai / 4ksplitter / pan-pan / obs) のうち**対応するアプリ**だけ、
   プロファイル毎の attach 経路を追加（既存の m48 経路は無変更）
4. 旧 v1 m48 経路は完全無傷で共存（名前が違うので物理的に交差しない）

---

## 4. 拡張ルール

### 4.1 既存プロファイル (m48) のままチャンネル追加 (低リスク・推奨)

byte 契約が ARPS v1 + プロファイル `m48` のままで shm 名だけ増やす場合:

1. `audio-router` で **新 shm 名の eager-create を追加** (`ShmSender.splitterName(slot:)` 等の
   helper を拡張、または個別命名)。
2. 受信側 (例: babigoe-kai) で attach 名を切替可能に。
3. **本ドキュメント §5 台帳に新名を追記**。
4. 4ksplitter/OBS plugin は対象 sink/source として登録が必要な場合のみ更新。
5. 既存名 (枠1) は **literal 据置**＝完全後方互換。

5 repo 同時 push は **不要** (audio-router + 受信側 1 つで足りる)。

### 4.2 新プロファイル追加 (中リスク・関係 repo のみ)

同じ ARPS v1 ヘッダ構造を保ったまま、新しい `<fmt>` (例: `st48`, `m96`) を投入する場合:

1. 本ドキュメント §3.4 表に新プロファイル行を追加 (channels / sampleRate / capacity / totalBytes)。
2. `audio-router` の `ShmSender` / `ShmReader` で profile を引数に取れるよう一般化
   （現状は capacity 等が定数なので、プロファイル別に差し替え or 引数化）。
3. **対応したいアプリ** (例: VST 入出力に stereo が欲しい babigoe-kai) で
   新文法 `/<ns>.g1.<fmt>.<slot>` を使う attach 経路を追加。
4. 旧 `m48` 経路は **literal 据置**。プロファイルごとに名前が違うので物理的に非交差。
5. 関係しないアプリ (pan-pan / 4ksplitter で st48 不要なら) は **無変更**で OK。

ヘッダ §2 構造は変えないので「契約バンプ」(§4.3) より低リスク。受信側の attach 検証は
**名前から導出した profile** と照合する (固定値ではない)。

### 4.3 ヘッダ構造を変える (高リスク・5 repo 同時)

ヘッダフィールド追加、レイアウト変更、`version` を 1→2 へ上げる等。

1. **新文法 `<namespace>.<gen>.<fmt>.<slot>`** で **新名を採り並存** (旧名は touch しない)。
2. 5 repo 全てで attach/create コードを追加。byte レイアウトを §2 に追記しヘッダ
   `version` を上げる。
3. 旧版 v1 経路は無変更で共存可能 (名前が違うので物理的に交差しない)。
4. 切替判断はアプリ単位 (旧 v1 / 新 v2 のどちらに attach するか)。

例: `/4ksp.g2.st.1` (ARPSv2/stereo48k/枠1) を追加すると、`/4ksp.voice3` (v1/mono48k) は
そのまま残し、stereo 対応アプリは新名へ attach する。

---

## 5. 現行台帳 (registry)

ステータス: ✅=実装稼働 / 🛠=設計のみ / 📦=将来予定 / 🚮=廃止予定 (deprecated)

### 5.1 ARPS v1 / プロファイル `m48` (mono 48k)

| 名前 | 向き | 所有 (create) | 書き手 | 読み手 | 用途 | ステータス |
|---|---|---|---|---|---|---|
| `/4ksp.voice3`      | router→4ksp | audio-router | audio-router | 4ksplitter | LipSync 入力 (枠1) | ✅ |
| `/4ksp.voice3.2`    | router→4ksp | audio-router | audio-router | 4ksplitter | LipSync 入力 (枠2) | 🛠 [multi-voice-slots-design.md](./multi-voice-slots-design.md) |
| `/4ksp.voice3.3`    | router→4ksp | audio-router | audio-router | 4ksplitter | LipSync 入力 (枠3) | 🛠 同上 |
| `/4ksp.voice3.4`    | router→4ksp | audio-router | audio-router | 4ksplitter | LipSync 入力 (枠4) | 🛠 同上 |
| `/babigoe.in3`      | router→babigoe | audio-router | audio-router | babigoe-kai | mic 供給 (ch1) | ✅ |
| `/babigoe.out3`     | babigoe→router | audio-router | babigoe-kai  | audio-router | 声質変換後回収 (ch1) | ✅ |
| `/babigoe-in.g1.m48.1`  | router→babigoe | audio-router | audio-router | babigoe-kai (VSTデッキ) | mic 供給 (VST channel) | ✅ |
| `/babigoe-out.g1.m48.1` | babigoe→router | audio-router | babigoe-kai (VSTデッキ) | audio-router | VST 処理後回収 | ✅ |
| `/babigoe-in.g1.m48.2..3`  | router→babigoe | audio-router | audio-router | babigoe-kai | 予約 (将来の追加チャンネル) | 📦 |
| `/babigoe-out.g1.m48.2..3` | babigoe→router | audio-router | babigoe-kai  | audio-router | 予約 | 📦 |
| `/babigoe.in3.<2..4>`   | (廃止予定)   | -            | -            | -           | §3.3 短期暫定運用。新規利用は §3.2 新文法へ。下記 deprecated | 🚮 |
| `/babigoe.out3.<2..4>`  | (廃止予定)   | -            | -            | -           | 同上 | 🚮 |

### 5.2 ARPS v1 / 拡張プロファイル (`st48` / `m96` / `st96` ほか)

未実装。stereo/高サンプルレートが必要になった repo が個別に新名で立ち上げ。
名前文法 §3.2、プロファイル定義 §3.4。

| 名前パターン | 想定用途 | ステータス |
|---|---|---|
| `/babigoe.g1.st48.<slot>` | stereo VST 経路 (空間系プラグイン用途) | 📦 |
| `/4ksp.g1.st48.<slot>`    | stereo 動画素材経由の 4ksplitter 入力 | 📦 |
| `/4ksp.g1.m96.<slot>`     | 高音質 mono 収録経路 | 📦 |
| `/<ns>.g1.st96.<slot>`    | 高音質 stereo (音楽用) | 📦 |

### 5.3 ARPS v2 (ヘッダ構造変更時のみ・予約)

未実装。ヘッダフィールド追加・レイアウト変更が必要になった場合のみ。

| 名前パターン | 想定用途 |
|---|---|
| `/<ns>.g2.<fmt>.<slot>` | ARPSv2 ヘッダの新フィールド利用時 |

---

## 6. 各リポジトリでの実装ポイント

| リポジトリ | 役割 | 主要ファイル |
|---|---|---|
| `audio-router` (Swift) | 全 shm の eager-create / source-sink 接続 / 生存監視 | `Sources/AudioRouterCore/ShmSender.swift` / `ShmReader.swift` / `Sources/AudioRouterApp/RouterController.swift` |
| `4ksplitter_` (Unity C#) | attach 専用 / `consumerPid` 書込 / LipSync 駆動 | `Assets/VRig/VoiceShmReceiver.cs` |
| `babigoe-kai` (.NET) | attach 専用 / 双方向 (`/babigoe.in3` read + `/babigoe.out3` write) | `src/BabigoeMac/Audio/Arp1ShmReader.cs` / `Arp1ShmWriter.cs` |
| `pan-pan` (.NET) | attach 専用 / 効果音抽出経路 | (audio-router 経由参照) |
| `obs-plugins/obs-audio-router-shm` (C/Obj-C++) | attach 専用 / OBS filter 経路 | (audio-router 経由参照) |

共通制約:

- **`O_CREAT` してよいのは audio-router (Swift CShmCompat) のみ**。
- 受信側は **`O_RDWR` の 2 引数 open** (3 引数版は ABI 不整合の歴史あり)。
- attach 直後に `magic`/`version`/`channels`/`capacity` を §2 と照合。不一致なら attach 拒否。
- 受信開始時に `consumerPid` フィールドへ自 PID を書込む (audio-router が `kill(pid,0)` で生存監視)。
- プロセス終了時 `shm_unlink` を**呼んではならない** (audio-router が一手に管理)。

**既知の逸脱 (deviation)**

- `obs-plugins/obs-audio-router-shm` の **`allow_create` 設定** はテスト/開発用の
  escape hatch で、有効時に OBS が `O_CREAT` を呼べる。本仕様からは逸脱。
  既定 `false`、UI で明示 opt-in 時のみ動作し、有効時は `LOG_WARNING` で警告される。
  本番運用では **audio-router を立ち上げて attach** すること。

---

## 7. 変更履歴

- 2026-05-22: 初版作成 (蓄積していたレガシー名・新文法・台帳を集約)。
- 2026-05-22: `/babigoe.in3.2` `/babigoe.out3.2` を実装稼働へ昇格。audio-router の
  `babigoeSlot` 対応 (ShmSender.babigoeInName / ShmReader.babigoeOutName / RouteEdge.babigoeSlot
  / ContentView Picker)、babigoe-kai の VST デッキを ch2 へ向け。全 5 repo の
  attach 検証も §2 全項目 (magic/version/channels/capacity) に揃えた。OBS の
  allow_create は spec 逸脱として §6 に明記。
- 2026-05-22: §3.4 **音質プロファイル台帳**を新設。`<fmt>` を `m`/`st` の 2 値から
  `m44`/`m48`/`m96`/`st44`/`st48`/`st96` のプロファイル ID に拡張し、sampleRate と
  channels を制御可能に。ヘッダ §2 構造は v1 のまま、capacity 計算式と attach 検証
  だけがプロファイル依存になる。§4 を §4.1/§4.2/§4.3 の 3 段階拡張ルールに整理
  （プロファイル追加 = 中リスク、関係 repo のみ更新）。実装はまだ。
- 2026-05-22: babigoe-kai / audio-router に `ShmProfile` 型を実装。Reader/Writer/Sender が
  プロファイル受領 (既定 m48)、attach 検証は sampleRate も含めた全項目に拡張。
- 2026-05-22: VST チャンネルの shm 名を §3.3 短期暫定運用 (`/babigoe.in3.2` 等) から
  §3.2 新文法 (`/babigoe-in.g1.m48.1` / `/babigoe-out.g1.m48.1`) へ移行。namespace に
  `-in` / `-out` 接尾辞を付けて方向を分離する慣習を §3.2 に追記。
  旧 §3.3 拡張は §5 で 🚮 廃止予定マークに降格。
- (将来) ARPS v2 ヘッダ構造変更時に §5.3 を実装ステータスへ昇格・§2 にレイアウト追記。
