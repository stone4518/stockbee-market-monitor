#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "此构建脚本须在macOS 13+执行（当前非macOS）。"
  exit 1
fi
if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "未找到Apple Swift编译器。请先安装Xcode或Command Line Tools: xcode-select --install"
  exit 1
fi
APP="dist/Stockbee Market Monitor.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp MacApp/Info.plist "$APP/Contents/Info.plist"
# Generate .icns with native macOS tools, when available.
if command -v sips >/dev/null && command -v iconutil >/dev/null; then
  ICONSET="dist/StockbeeMac.iconset"
  mkdir -p "$ICONSET"
  for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" MacApp/AppIcon1024.png --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    TWO=$((SIZE * 2))
    sips -z "$TWO" "$TWO" MacApp/AppIcon1024.png --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
fi
echo "正在检查Swift核心逻辑..."
swift test -j 2
echo "正在构建macOS原生应用..."
xcrun swiftc \
 -target "$(uname -m)-apple-macosx13.0" \
 -parse-as-library \
 -O \
 -framework SwiftUI -framework Charts -framework AppKit \
 Sources/StockbeeCore/Core.swift \
 Sources/StockbeeCore/Parsing.swift \
 Sources/StockbeeCore/Network.swift \
 MacApp/MonitorModel.swift \
 MacApp/ContentView.swift \
 MacApp/StockbeeMacApp.swift \
 -o "$APP/Contents/MacOS/StockbeeMac"
chmod +x "$APP/Contents/MacOS/StockbeeMac"
# Local ad-hoc signature is not Apple notarization, but helps permit opening locally.
if command -v codesign >/dev/null; then
  codesign --force --deep --sign - "$APP" || true
fi
echo "创建供本机分发的ZIP..."
rm -f dist/StockbeeMarketMonitor-macOS.zip
ditto -c -k --keepParent --sequesterRsrc "$APP" dist/StockbeeMarketMonitor-macOS.zip
echo "成功：$APP"
echo "ZIP：dist/StockbeeMarketMonitor-macOS.zip"
echo "首次运行可右键应用，选择‘打开’，或在系统设置的隐私与安全性中放行。"
