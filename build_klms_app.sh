#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="KLMS Sync"
APP_DIR="$SCRIPT_DIR/$APP_NAME.app"
BUILD_ROOT="${KLMS_APP_INSTALL_DIR:-$HOME/Applications}"
REAL_APP_DIR="$BUILD_ROOT/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
SOURCE_FILE="$SCRIPT_DIR/src/swift/KLMSControlCenter.swift"
ICON_SOURCE_FILE="$SCRIPT_DIR/src/swift/GenerateKLMSAppIcon.swift"
EXECUTABLE_PATH="$MACOS_DIR/$APP_NAME"
MODULE_CACHE_DIR="$SCRIPT_DIR/.build/module-cache"
ICON_BUILD_DIR="$SCRIPT_DIR/.build/app-icon"
ICONSET_DIR="$ICON_BUILD_DIR/AppIcon.iconset"

if [[ ! -f "$SOURCE_FILE" ]]; then
  print -r -- "Missing source file: $SOURCE_FILE" >&2
  exit 1
fi
if [[ ! -f "$ICON_SOURCE_FILE" ]]; then
  print -r -- "Missing icon source file: $ICON_SOURCE_FILE" >&2
  exit 1
fi

rm -rf "$APP_DIR" "$REAL_APP_DIR"
APP_DIR="$REAL_APP_DIR"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
EXECUTABLE_PATH="$MACOS_DIR/$APP_NAME"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$MODULE_CACHE_DIR"
printf 'KLMS Sync Control Center\n' > "$RESOURCES_DIR/README.txt"

cat > "$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>ko</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>local.klms.sync.control-center</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>KLMS 페이지 수집과 동기화를 위해 Safari, Reminders, Calendar, Notes 자동화 권한을 사용합니다.</string>
  <key>NSCalendarsUsageDescription</key>
  <string>KLMS 과제와 시험 일정을 Calendar에 동기화하기 위해 캘린더 접근 권한을 사용합니다.</string>
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>KLMS 과제와 시험 일정을 생성, 갱신, 삭제하기 위해 Calendar 전체 접근 권한을 사용합니다.</string>
  <key>NSHumanReadableCopyright</key>
  <string>Local KLMS Sync utility</string>
  <key>KLMSProjectRoot</key>
  <string>$SCRIPT_DIR</string>
</dict>
</plist>
EOF

rm -rf "$ICON_BUILD_DIR"
mkdir -p "$ICON_BUILD_DIR"
/usr/bin/swift \
  -module-cache-path "$MODULE_CACHE_DIR" \
  "$ICON_SOURCE_FILE" \
  "$ICONSET_DIR"

/usr/bin/iconutil \
  -c icns \
  "$ICONSET_DIR" \
  -o "$RESOURCES_DIR/AppIcon.icns"

/usr/bin/swiftc \
  -O \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE_DIR" \
  -Xlinker -no_adhoc_codesign \
  -framework AppKit \
  -framework EventKit \
  -framework Foundation \
  -framework SwiftUI \
  -framework UniformTypeIdentifiers \
  "$SOURCE_FILE" \
  -o "$EXECUTABLE_PATH"

chmod +x "$EXECUTABLE_PATH"

if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$APP_DIR" >/dev/null 2>&1 || true
fi

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_DIR"
fi

ln -s "$REAL_APP_DIR" "$SCRIPT_DIR/$APP_NAME.app"

print -r -- "Built $REAL_APP_DIR"
print -r -- "Linked $SCRIPT_DIR/$APP_NAME.app"
