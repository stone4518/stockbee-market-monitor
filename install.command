#!/bin/bash
# 一键安装：把同目录（或 dist/）中的 Stockbee Market Monitor.app 复制到 /Applications，并去除下载隔离标记。
set -euo pipefail
cd "$(dirname "$0")"
SRC=""
for p in "Stockbee Market Monitor.app" "dist/Stockbee Market Monitor.app" "/Volumes/Stockbee Market Monitor/Stockbee Market Monitor.app"; do
  [[ -d "$p" ]] && { SRC="$p"; break; }
done
[[ -z "$SRC" ]] && { echo "未找到 Stockbee Market Monitor.app（请先运行 build-mac.command 或打开 DMG）"; exit 1; }
DEST="/Applications/Stockbee Market Monitor.app"
echo "安装：$SRC → $DEST"
rm -rf "$DEST"
ditto "$SRC" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
echo "完成。正在打开…"
open "$DEST"
