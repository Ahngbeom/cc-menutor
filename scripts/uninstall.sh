#!/bin/bash
# cc-menutor 원격 제거 스크립트
# 사용법: curl -fsSL https://raw.githubusercontent.com/Ahngbeom/cc-menutor/main/scripts/uninstall.sh | bash
set -euo pipefail

INSTALL_DIR="${HOME}/.local/share/cc-menutor"

if [ -x "$INSTALL_DIR/uninstall.sh" ]; then
  "$INSTALL_DIR/uninstall.sh"
else
  # 설치 디렉터리가 없거나 손상된 경우 LaunchAgent만 직접 정리
  launchctl bootout "gui/$(id -u)/io.github.ahngbeom.claude-monitor" 2>/dev/null || true
  rm -f "${HOME}/Library/LaunchAgents/io.github.ahngbeom.claude-monitor.plist"
fi

rm -rf "$INSTALL_DIR"
echo "✅ 제거 완료."
