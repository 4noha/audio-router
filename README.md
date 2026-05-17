# audio-router

macOS 14.4+ 専用の **per-app 音声ルーター**（Swift + SwiftUI / スタンドアロン）。

特定アプリ（VLC 等）の出力音声を Apple Core Audio の **プロセスタップ API**
（`AudioHardwareCreateProcessTap` / `CATapDescription`, macOS 14.4+）で捕捉し、

- **TO-1: モニタ出力** — 任意の出力デバイス（スピーカー等）へ流して自分でも聴く
- **TO-2: 4ksplitter 連携** — ドライバ不要の汎用 UDP/PCM で 4ksplitter へ送出

の2系統へ同時に分配する。UI（FROM/TO リスト・ON/OFF トグル）はすべて本アプリ側。
4ksplitter には UI 責務を持たせず、裏方の UDP 受信のみ（設定フラグで有効化）。

## 設計境界

- 仮想オーディオドライバ（BlackHole/AudioServerPlugIn 等）は**作らない/不要**。
  4ksplitter への橋渡しは下記 UDP/PCM の独自規格。
- per-app 捕捉なので「VLC だけ」を対象にでき、他アプリ/システム音は混ざらない。
- VLC 側の設定は変更不要（出力先を触らない）。

## 4ksplitter 連携ワイヤーフォーマット（契約・v1）

これは audio-router（送信）と 4ksplitter 受信側の**固定契約**。変更時は両者同時更新。

- トランスポート: **UDP**、既定 `127.0.0.1:7878`
- データグラム = **16 byte ヘッダ + ペイロード**、すべてリトルエンディアン

| offset | size | 内容 |
|--------|------|------|
| 0..3   | 4    | magic = ASCII `"ARP1"`（0x41 0x52 0x50 0x31） |
| 4      | 1    | version = 1 |
| 5      | 1    | channels（1 = mono） |
| 6..7   | 2    | reserved（0） |
| 8..11  | 4    | sampleRate（uint32, 既定 48000） |
| 12..15 | 4    | sequence（uint32, 単調増加・ラップ可） |
| 16..   | N×4  | ペイロード: interleaved **Float32 LE** PCM サンプル |

- 既定: **mono / Float32 / 48000 Hz**
- 1 データグラムは IP フラグメント回避のため概ね ≤ 1200 byte（≈ 288 frames/packet）
- 再送なし。リップシンク用途のためパケットロス許容（連続性 > 完全性）
- `sequence` は受信側のロス検知・順序破棄用（厳密な再整列はしない）

## ビルド

```bash
cd ~/works/audio-router
swift build -c release
scripts/make_app.sh        # AudioRouter.app を dist/ に生成（ad-hoc 署名）
open dist/AudioRouter.app
```

## 権限について（重要）

他プロセス音声のタップは macOS の許可ダイアログが出る。アプリは適切な
コード署名 + Info.plist の使用目的文字列が必要。ローカル運用は ad-hoc 署名
（`make_app.sh`）で可。初回に許可を与えること。Editor/CI では検証不可。
