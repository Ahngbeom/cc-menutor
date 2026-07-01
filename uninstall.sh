#!/bin/bash
# claude-monitor uninstall script

PLIST="$HOME/Library/LaunchAgents/io.github.ahngbeom.claude-monitor.plist"

if [ -f "$PLIST" ]; then
  launchctl unload "$PLIST" 2>/dev/null && echo "✅ 서비스 중지됨" || true
  rm -f "$PLIST"
  echo "✅ LaunchAgent 제거됨"
else
  # launchctl로 직접 종료 시도
  launchctl stop io.github.ahngbeom.claude-monitor 2>/dev/null || true
  pkill -f "ClaudeMonitor" 2>/dev/null && echo "✅ 프로세스 종료됨" || echo "실행 중인 프로세스 없음"
fi

echo "완료."
