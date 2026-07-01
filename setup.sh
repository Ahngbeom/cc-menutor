#!/bin/bash
# 한 번에 빌드 + 설치 + 실행
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Claude Code Usage Monitor 설치"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 권한 부여
chmod +x "$SCRIPT_DIR/build.sh" "$SCRIPT_DIR/install.sh" "$SCRIPT_DIR/uninstall.sh"

# 빌드
"$SCRIPT_DIR/build.sh"

# LaunchAgent 등록
"$SCRIPT_DIR/install.sh"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 완료! 메뉴바를 확인하세요."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
