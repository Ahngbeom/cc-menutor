#!/bin/bash
# cc-menutor 원격 제거 스크립트
# 사용법: curl -fsSL https://raw.githubusercontent.com/Ahngbeom/cc-menutor/main/scripts/uninstall.sh | bash
set -euo pipefail

INSTALL_DIR="${HOME}/.local/share/cc-menutor"

if [ -x "$INSTALL_DIR/uninstall.sh" ]; then
  "$INSTALL_DIR/uninstall.sh"
else
  # 설치 디렉터리가 없거나 손상된 경우 LaunchAgent만 직접 정리
  # (신규 cc-menutor + 리브랜딩 이전 claude-monitor 둘 다 방어적으로 정리)
  for label in "io.github.ahngbeom.cc-menutor" "io.github.ahngbeom.claude-monitor"; do
    launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
    rm -f "${HOME}/Library/LaunchAgents/${label}.plist"
  done
fi

rm -rf "$INSTALL_DIR"
echo "✅ 제거 완료."
