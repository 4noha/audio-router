#!/bin/bash
# yt-translator のライブ字幕サービス (serve_engine) を audio-router ルートから
# 起動する薄いラッパ。
#
# 前提: /obs.mic3.2 に音声が供給されていること。供給はどちらか片方
# (1 枠 1 書き手、docs/arps-shm-spec.md §5.1):
#   a) AudioRouter でマイクの bus をもう 1 行 fan-out して
#      「OBS マイク#2」sink を ON にする
#   b) OBS 内の字幕対象ソース (例: AudioRouter SHM Input) に
#      「AudioRouter SHM Output」フィルタを付け、preset「OBS マイク#2」
#      + allow_create ON にする — 字幕対象を OBS 側で指定する運用
# OBS 本体の「AudioRouter SHM Input」が読む枠 (通常 /obs.mic3) と同じ枠は
# 使わない (ARPS は 1 shm = 1 consumer。docs/arps-shm-spec.md §6)。
#
# 使い方:
#   scripts/yt_subtitles.sh                     # /obs.mic3.2 + overlay :8765
#   scripts/yt_subtitles.sh --arps /obs.mic3.3  # 別スロット
#   scripts/yt_subtitles.sh --comments -        # コメント翻訳も並走
# 追加引数はそのまま serve_engine.py へ渡る。OBS ブラウザソースには
# http://localhost:8765/ を貼る。
set -euo pipefail
YT_ROOT="$(cd "$(dirname "$0")/../../yt-translator" && pwd)"
cd "$YT_ROOT"
exec uv run python scripts/serve_engine.py --arps --sse 8765 "$@"
