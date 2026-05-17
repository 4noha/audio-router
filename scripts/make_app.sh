#!/bin/bash
# AudioRouter.app を dist/ に生成（リリースビルド + Info.plist + ad-hoc 署名）。
# ローカル運用専用。配布時は正式な Developer ID 署名へ差し替えること。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/dist/AudioRouter.app"
BIN_NAME="AudioRouterApp"

echo "==> swift build -c release"
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)/$BIN_NAME"
[ -x "$BIN_PATH" ] || { echo "binary not found: $BIN_PATH"; exit 1; }

echo "==> assemble app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/AudioRouter"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>AudioRouter</string>
  <key>CFBundleDisplayName</key>     <string>Audio Router</string>
  <key>CFBundleIdentifier</key>      <string>com.4noha.audiorouter</string>
  <key>CFBundleExecutable</key>      <string>AudioRouter</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleVersion</key>         <string>1</string>
  <key>CFBundleShortVersionString</key> <string>1.0</string>
  <key>LSMinimumSystemVersion</key>  <string>14.4</string>
  <key>LSUIElement</key>             <false/>
  <key>NSHighResolutionCapable</key> <true/>
  <key>NSAudioCaptureUsageDescription</key>
  <string>VLC 等のアプリ音声を捕捉して 4ksplitter のリップシンクへ送ります。</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>per-app 音声タップのために音声入力権限を使用します。</string>
</dict>
</plist>
PLIST

cat > "$ROOT/dist/AudioRouter.entitlements" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.device.audio-input</key> <true/>
</dict>
</plist>
ENT

echo "==> ad-hoc codesign"
codesign --force --deep --sign - \
  --entitlements "$ROOT/dist/AudioRouter.entitlements" \
  "$APP"

echo "==> done: $APP"
echo "起動: open \"$APP\"  （初回に音声捕捉の許可を与えること）"
