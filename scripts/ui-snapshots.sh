#!/bin/bash
# 实际启动 .app 并截图：正常窗口、小窗口、断网+缓存、断网无缓存。
set -u
APP_BIN="dist/Stockbee Market Monitor.app/Contents/MacOS/StockbeeMac"
OUT="${1:-artifacts/ui}"; mkdir -p "$OUT"
rm -rf "$HOME/Library/Application Support/StockbeeMarketMonitor"
run() { local name="$1"; shift; echo "== $name"; ( "$@" ) & local pid=$!
        for _ in $(seq 1 150); do kill -0 $pid 2>/dev/null || break; sleep 1; done
        kill -0 $pid 2>/dev/null && { echo "超时，结束进程"; kill $pid; }
        wait $pid; echo "退出码 $?"; cat "$OUT/$name.png.txt" 2>/dev/null; echo; }
run 01_正常_1480x1000 "$APP_BIN" --snapshot "$OUT/01_正常_1480x1000.png" --size 1480x1000
run 00_完整内容_离屏整页 "$APP_BIN" --snapshot "$OUT/00_完整内容_离屏整页.png" --size 1480x1000 --full
run 02_小窗口_1120x720 "$APP_BIN" --snapshot "$OUT/02_小窗口_1120x720.png" --size 1120x720
run 03_断网_有缓存 env STOCKBEE_FORCE_OFFLINE=1 "$APP_BIN" --snapshot "$OUT/03_断网_有缓存.png" --size 1480x1000
run 04_断网_无缓存 env STOCKBEE_FORCE_OFFLINE=1 STOCKBEE_NO_CACHE=1 "$APP_BIN" --snapshot "$OUT/04_断网_无缓存.png" --size 1480x1000
# 系统级截屏（独立于应用内渲染），验证真实窗口可见
"$APP_BIN" & PID=$!; sleep 30; screencapture -x "$OUT/05_系统截屏_全屏.png" || echo "screencapture 失败"; kill $PID 2>/dev/null
ls -la "$OUT"; ls -la "$HOME/Library/Application Support/StockbeeMarketMonitor" || true
exit 0
