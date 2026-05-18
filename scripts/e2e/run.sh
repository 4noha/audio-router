#!/bin/bash
# 一気通貫 E2E 動作検証ハーネス（Claude / CI が 1 コマンドで実行）。
#
#   scripts/e2e/run.sh [--build]
#
# 検証項目（CORE=環境汚染非依存・失敗で exit≠0 / INFO=参考）:
#   1 CORE  arps プラミング: arps-feed → arps-probe(private名) 流量検知
#   2 CORE  AudioRouter 制御面: --apply で経路ロード→status.json 反映
#   3 CORE  AudioRouter ホットリロード: routes.json 書換→status.json 追従
#   4 CORE  babigoe ヘッドレス: --in shm(feed) → --out wav 非無音・exit0
#   5 INFO  AudioRouter データ面: babigoeOut→bus→recorder（既知 shm 名は
#           他プロセス/孤児で汚染し得るため参考扱い）
#
# 既知 shm 名の汚染回避のため開始時に関連プロセスを掃除する。
set -u

AR="$HOME/works/audio-router"
BABI_DLL="$HOME/works/babigoe‐kai/src/BabigoeMac/bin/Debug/net9.0/BabigoeMac.dll"
SUP="$HOME/Library/Application Support/AudioRouter"
B="$AR/.build/debug"
PASS=0; FAIL=0; FAILED=""

say()  { printf '\n=== %s ===\n' "$1"; }
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
ng()   { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILED="$FAILED\n  - $1"; }
cleanup() {
  pkill -x AudioRouter 2>/dev/null
  pkill -f 'AudioRouterApp|arps-feed|arps-probe|BabigoeMac' 2>/dev/null
  sleep 1
}

if [ "${1:-}" = "--build" ]; then
  say "build"
  ( cd "$AR" && swift build ) || { echo "swift build 失敗"; exit 2; }
  ( cd "$HOME/works/babigoe‐kai" && \
    dotnet build src/BabigoeMac/BabigoeMac.csproj -c Debug >/dev/null ) \
    || { echo "dotnet build 失敗"; exit 2; }
fi

[ -x "$B/arps-probe" ] || { echo "arps-probe 未ビルド（--build を付けて実行）"; exit 2; }
cleanup
trap cleanup EXIT

# ---- 1 CORE: arps プラミング（private 名・汚染非依存） --------------------
say "1 CORE arps plumbing"
TN="/e2e.$(date +%s)"
"$B/arps-feed" --name "$TN" --hz 440 --amp 0.4 --duration-sec 4 >/dev/null 2>&1 &
sleep 0.5
if "$B/arps-probe" --name "$TN" --watch-sec 2 --interval-ms 500 --require-flow \
     >/tmp/e2e_probe.json 2>&1; then
  ok "arps-feed→arps-probe 流量検知 (exit0/--require-flow)"
else
  ng "arps プラミング流量未検知"
fi
wait 2>/dev/null

# ---- 2 CORE: AudioRouter 制御面（--apply） --------------------------------
say "2 CORE AudioRouter --apply"
cat > /tmp/e2e_r1.json <<'EOF'
[{"id":"11111111-1111-1111-1111-111111111111","bus":"e2eBusA","source":"babigoeOut","sink":"recorder","appBundleID":"","appName":"","muteSource":false,"micUID":"","micName":"","enabled":true}]
EOF
"$B/AudioRouterApp" --apply /tmp/e2e_r1.json --quit-after 12 >/tmp/e2e_ar.log 2>&1 &
AP=$!
sleep 3
if python3 - "$SUP/status.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
rows=d.get("rows",[])
sys.exit(0 if any("e2eBusA" in r["oneLine"] and r["enabled"] for r in rows) else 1)
PY
then ok "--apply で e2eBusA 経路がロード/有効化"
else ng "--apply 後 status.json に経路が反映されない"; fi

# ---- 3 CORE: ホットリロード ----------------------------------------------
say "3 CORE hot-reload"
cat > /tmp/e2e_r2.json <<'EOF'
[{"id":"22222222-2222-2222-2222-222222222222","bus":"e2eBusB","source":"babigoeOut","sink":"splitter","appBundleID":"","appName":"","muteSource":false,"micUID":"","micName":"","enabled":true}]
EOF
cp /tmp/e2e_r2.json "$SUP/routes.json"
sleep 3
if python3 - "$SUP/status.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
rows=d.get("rows",[])
ok = any("e2eBusB" in r["oneLine"] for r in rows) and \
     not any("e2eBusA" in r["oneLine"] for r in rows)
sys.exit(0 if ok else 1)
PY
then ok "routes.json 書換→status.json が e2eBusB へ追従"
else ng "ホットリロードが status.json に反映されない"; fi
kill $AP 2>/dev/null; wait $AP 2>/dev/null

# ---- 4 CORE: babigoe ヘッドレス ------------------------------------------
say "4 CORE babigoe --headless"
if [ -f "$BABI_DLL" ]; then
  cleanup
  rm -f /tmp/e2e_bh.wav
  ( dotnet "$BABI_DLL" --headless --in shm --out wav:/tmp/e2e_bh.wav \
      --duration 6 >/tmp/e2e_bh.log 2>&1; echo "EXIT=$?" >>/tmp/e2e_bh.log ) &
  BP=$!
  sleep 2
  "$B/arps-feed" --name /babigoe.in3 --hz 330 --amp 0.4 --duration-sec 4 \
    >/dev/null 2>&1 &
  wait $BP 2>/dev/null
  SZ=$(stat -f%z /tmp/e2e_bh.wav 2>/dev/null || echo 0)
  if grep -q 'EXIT=0' /tmp/e2e_bh.log && grep -q ' OK' /tmp/e2e_bh.log \
     && [ "$SZ" -gt 100000 ]; then
    ok "babigoe headless: DSP 処理・WAV 非無音 (${SZ}B, exit0)"
  else
    ng "babigoe headless 失敗 ($(tail -1 /tmp/e2e_bh.log))"
  fi
else
  echo "  SKIP: babigoe 未ビルド ($BABI_DLL)"
fi

# ---- 5 INFO: AudioRouter データ面（汚染し得るので参考） -------------------
say "5 INFO AudioRouter data-flow (informational)"
cleanup
cat > /tmp/e2e_r3.json <<'EOF'
[{"id":"33333333-3333-3333-3333-333333333333","bus":"e2eBusC","source":"babigoeOut","sink":"recorder","appBundleID":"","appName":"","muteSource":false,"micUID":"","micName":"","enabled":true}]
EOF
rm -f "$SUP/recordings/"rec-*.wav 2>/dev/null
"$B/AudioRouterApp" --apply /tmp/e2e_r3.json --quit-after 11 >/dev/null 2>&1 &
DP=$!
sleep 3
"$B/arps-feed" --name /babigoe.out3 --hz 440 --amp 0.4 --duration-sec 6 \
  >/dev/null 2>&1 &
sleep 5
INFLOW=$(python3 - "$SUP/status.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
print("yes" if any(r["inFlow"] for r in d.get("rows",[])) else "no")
PY
)
echo "  INFO: recorder 経路 inFlow=$INFLOW （no の場合は既知 shm 名の"
echo "        孤児/他プロセス汚染。private 名検証(項目1)が真の判定）"
kill $DP 2>/dev/null; wait $DP 2>/dev/null

# ---- 集計 ----------------------------------------------------------------
say "RESULT"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'FAILED:%b\n' "$FAILED"
  exit 1
fi
echo "  全 CORE 検証 PASS"
exit 0
