#!/bin/bash
# cc-menutor uninstall script

# 신규(cc-menutor) + 구버전(claude-monitor) Label 둘 다 방어적으로 정리 —
# 리브랜딩 전/후 어느 버전이 설치돼 있든 완전히 제거되게 한다.
NEW_LABEL="io.github.ahngbeom.cc-menutor"
OLD_LABEL="io.github.ahngbeom.claude-monitor"

removed=false
for label in "$NEW_LABEL" "$OLD_LABEL"; do
  plist="$HOME/Library/LaunchAgents/${label}.plist"
  if [ -f "$plist" ]; then
    launchctl unload "$plist" 2>/dev/null || true
    rm -f "$plist"
    removed=true
  fi
done

if [ "$removed" = true ]; then
  echo "✅ LaunchAgent 제거됨"
else
  # launchctl로 직접 종료 시도
  launchctl stop "$NEW_LABEL" 2>/dev/null || true
  launchctl stop "$OLD_LABEL" 2>/dev/null || true
fi

# -x(정확한 프로세스명 일치)로 종료 — -f(전체 명령행)를 쓰면 실행 경로에 "cc-menutor"가
# 포함된 이 스크립트 자신(예: ~/.local/share/cc-menutor/uninstall.sh)까지 죽일 위험이 있다.
killed=false
pkill -x "cc-menutor" 2>/dev/null && { echo "✅ 프로세스 종료됨"; killed=true; } || true
pkill -x "ClaudeMonitor" 2>/dev/null && { echo "✅ 프로세스 종료됨(구버전)"; killed=true; } || true
[ "$killed" = true ] || echo "실행 중인 프로세스 없음"

echo "완료."
