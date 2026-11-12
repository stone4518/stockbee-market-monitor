#!/bin/bash
# Stockbee Market Monitor 本地构建脚本（macOS 13+，需 Xcode 或 Command Line Tools）
# 产物：dist/Stockbee Market Monitor.app（通用二进制 arm64+x86_64，ad-hoc 签名）
#       dist/StockbeeMarketMonitor-macOS.zip、dist/StockbeeMarketMonitor.dmg
set -euo pipefail
cd "$(dirname "$0")"
if [[ "$(uname -s)" != "Darwin" ]]; then echo "此构建脚本须在 macOS 13+ 执行。"; exit 1; fi
if ! xcrun --find swiftc >/dev/null 2>&1; then echo "未找到 Apple Swift 编译器，请先执行：xcode-select --install"; exit 1; fi

VERSION="${STOCKBEE_VERSION:-1.1.0}"
BUILD="${STOCKBEE_BUILD:-$(date +%Y%m%d%H%M)}"
APP="dist/Stockbee Market Monitor.app"
rm -rf "$APP" dist/StockbeeMarketMonitor-macOS.zip dist/StockbeeMarketMonitor.dmg dist/obj
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" dist/obj
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" MacApp/Info.plist > "$APP/Contents/Info.plist"

if command -v sips >/dev/null && command -v iconutil >/dev/null; then
  ICONSET="dist/StockbeeMac.iconset"; rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" MacApp/AppIcon1024.png --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    TWO=$((SIZE * 2)); sips -z "$TWO" "$TWO" MacApp/AppIcon1024.png --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"; rm -rf "$ICONSET"
fi

if [[ "${SKIP_TESTS:-0}" != "1" ]]; then echo "== 运行单元测试 =="; swift test -j 2; fi

echo "== 编译 macOS 原生应用（arm64 + x86_64）=="
SOURCES=(Sources/StockbeeCore/Core.swift Sources/StockbeeCore/Parsing.swift Sources/StockbeeCore/Network.swift
         MacApp/MonitorModel.swift MacApp/ContentView.swift MacApp/StockbeeMacApp.swift)
for ARCH in arm64 x86_64; do
  xcrun swiftc -target "$ARCH-apple-macosx13.0" -parse-as-library -O \
    -framework SwiftUI -framework Charts -framework AppKit "${SOURCES[@]}" -o "dist/obj/StockbeeMac-$ARCH"
done
lipo -create dist/obj/StockbeeMac-arm64 dist/obj/StockbeeMac-x86_64 -output "$APP/Contents/MacOS/StockbeeMac"
chmod +x "$APP/Contents/MacOS/StockbeeMac"
rm -rf dist/obj

# ad-hoc 签名：仅供本机运行，不是 Apple Developer ID 签名，也未公证。
codesign --force --deep --sign - "$APP"
codesign --verify --verbose=2 "$APP"

echo "== 打包 ZIP / DMG =="
ditto -c -k --keepParent --sequesterRsrc "$APP" dist/StockbeeMarketMonitor-macOS.zip
STAGE="dist/dmg-stage"; rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
[[ -f "docs/安装说明.txt" ]] && cp "docs/安装说明.txt" "$STAGE/"
hdiutil create -volname "Stockbee Market Monitor" -srcfolder "$STAGE" -ov -format UDZO dist/StockbeeMarketMonitor.dmg >/dev/null
rm -rf "$STAGE"
echo "成功：${APP}（版本 ${VERSION} / ${BUILD}）"
echo "ZIP：dist/StockbeeMarketMonitor-macOS.zip"
echo "DMG：dist/StockbeeMarketMonitor.dmg"
echo "首次打开：右键应用 →“打开”，或在 系统设置 → 隐私与安全性 中点“仍要打开”。"
