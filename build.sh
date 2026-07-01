#!/bin/bash
# claude-monitor build script
# Usage: ./build.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/ClaudeMonitor.swift"
OUT="$SCRIPT_DIR/ClaudeMonitor"
CACHE="/tmp/swiftmodulecache"

echo "🔨 Claude Monitor 빌드 시작..."
echo "   소스: $SRC"
echo "   출력: $OUT"
echo ""

mkdir -p "$CACHE"

swiftc \
  -module-cache-path "$CACHE" \
  -O \
  -framework Cocoa \
  -o "$OUT" \
  "$SRC"

echo "✅ 빌드 완료: $OUT"
echo ""

echo "🧪 셀프테스트 실행..."
"$OUT" --test
echo ""

echo "실행하려면:"
echo "  ./ClaudeMonitor"
echo ""
echo "로그인 시 자동 시작하려면:"
echo "  ./install.sh"
