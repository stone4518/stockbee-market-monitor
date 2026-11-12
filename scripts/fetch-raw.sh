#!/bin/bash
# 实际抓取 Stockbee 官网、其嵌入的 Google Sheet 及 ETF 行情原始响应，存档以便核对。
set -u
OUT="${1:-artifacts/raw}"; mkdir -p "$OUT"; cd "$OUT"
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 13_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
date -u +"抓取时间UTC %Y-%m-%dT%H:%M:%SZ" | tee fetch-log.txt
TZ=America/New_York date +"美东时间 %Y-%m-%d %H:%M %Z" | tee -a fetch-log.txt
f(){ curl -sS -L -m 40 -A "$UA" -o "$1" -w "$1 http=%{http_code} bytes=%{size_download} final=%{url_effective}\n" "$2" 2>&1 | tee -a fetch-log.txt; }
f mm.html "https://stockbee.blogspot.com/p/mm.html"
grep -o 'docs.google.com/spreadsheet[^"<> ]*' mm.html | sort -u | tee sheet-links.txt
f sheet_old_pub.html "https://docs.google.com/spreadsheet/pub?key=0Am_cU8NLIU20dEhiQnVHN3Nnc3B1S3J6eGhKZFo0N3c&output=html&widget=true"
f sheet_old_csv.csv "https://docs.google.com/spreadsheet/pub?key=0Am_cU8NLIU20dEhiQnVHN3Nnc3B1S3J6eGhKZFo0N3c&output=csv"
f sheet_new_csv.csv "https://docs.google.com/spreadsheets/d/1O6OhS7ciA8zwfycBfGPbP2fWJnR0pn2UUvFZVDP9jpE/pub?output=csv"
f sheet_new_pubhtml.html "https://docs.google.com/spreadsheets/d/1O6OhS7ciA8zwfycBfGPbP2fWJnR0pn2UUvFZVDP9jpE/pubhtml"
grep -o 'gid=[0-9]*' sheet_new_pubhtml.html | sort -u | tee -a fetch-log.txt
grep -o '"name":"[^"]*"' sheet_new_pubhtml.html | head -20 | tee -a fetch-log.txt
grep -o 'id="sheet-button-[0-9]*"[^<]*<a[^>]*>[^<]*' sheet_new_pubhtml.html | head -20 | tee -a fetch-log.txt
echo "=== new csv head ==="; head -40 sheet_new_csv.csv
echo "=== old csv head ==="; head -15 sheet_old_csv.csv
for s in SPY QQQ XLK SMH XLY; do
  f "yahoo_$s.json" "https://query1.finance.yahoo.com/v8/finance/chart/$s?range=6mo&interval=1d"
  f "stooq_$s.csv" "https://stooq.com/q/d/l/?s=$(echo $s | tr A-Z a-z).us&i=d"
done
head -c 600 yahoo_SPY.json; echo; head -3 stooq_SPY.csv
f stage2.html "https://us.stage2stocks.com/market-timing/market-monitor"
exit 0
