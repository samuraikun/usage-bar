#!/bin/bash
# UsageBar.app を組み立てて、ローカル用に署名する（ad-hoc 署名。Apple には何も送らない）。
#
#   scripts/build-app.sh            build.noindex/UsageBar.app を作る
#                                   （.noindex の付いたフォルダは Spotlight に索引されない。
#                                     Raycast や Spotlight の検索に、配置したアプリだけが出るようにするため）
#   scripts/build-app.sh --install  さらに ~/Applications/UsageBar.app へ配置する
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/build.noindex/UsageBar.app"
INSTALL_DIR="$HOME/Applications"

swift build -c release --product UsageBar
swift build -c release --product usagebar-bridge
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN/UsageBar" "$APP/Contents/MacOS/UsageBar"
cp "$BIN/usagebar-bridge" "$APP/Contents/MacOS/usagebar-bridge"
chmod 755 "$APP/Contents/MacOS/UsageBar" "$APP/Contents/MacOS/usagebar-bridge"

# 中継コマンドは Claude Code から起動され、~/.claude/usagebar/ と settings.json を書くため、
# サンドボックスには入れない。通信するコードは含まない（scripts/verify-security.sh で確認する）。
codesign --force --options runtime --timestamp=none --sign - \
  --identifier local.usagebar.bridge \
  "$APP/Contents/MacOS/usagebar-bridge"

# アプリ本体は App Sandbox に入れ、通信の権限を付けない。
codesign --force --options runtime --timestamp=none --sign - \
  --entitlements "$ROOT/Resources/UsageBar.entitlements" \
  "$APP"

codesign --verify --strict --verbose=1 "$APP"
echo "built: $APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$INSTALL_DIR"
  if pgrep -xq UsageBar; then
    pkill -x UsageBar || true
    sleep 1
  fi
  rm -rf "$INSTALL_DIR/UsageBar.app"
  ditto "$APP" "$INSTALL_DIR/UsageBar.app"
  # Finder・Raycast・Spotlight に新しいアイコンと情報を読み直させる。
  touch "$INSTALL_DIR/UsageBar.app"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALL_DIR/UsageBar.app"
  mdimport "$INSTALL_DIR/UsageBar.app" 2>/dev/null || true
  echo "installed: $INSTALL_DIR/UsageBar.app"
fi
