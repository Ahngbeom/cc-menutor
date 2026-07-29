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

# 런타임 부산물 정리 — 남겨두면 재설치 시 옛 상태(앵커/스트릭/자동보정 설정)를 그대로 물려받아
# "새로 설치했는데 예전 값이 보인다"가 된다. 설정까지 지우려면 --purge를 준다.
rm -f "$HOME/.cc-menutor.lock" "$HOME/.cc-menutor.log"

if [ "${1:-}" = "--purge" ]; then
  # 번들 ID 없는 bare 실행 파일이라 UserDefaults 도메인이 바이너리명에서 파생된다
  # (구버전 ClaudeMonitor 도메인도 함께 정리 — migrateLegacyDefaultsIfNeeded 참고).
  for domain in cc-menutor ClaudeMonitor; do
    defaults delete "$domain" 2>/dev/null || true
    rm -f "$HOME/Library/Preferences/${domain}.plist"
  done
  echo "✅ 사용자 설정(앵커·스트릭·표시 항목)까지 삭제됨"
else
  echo "ℹ️  사용자 설정은 보존했습니다. 완전히 지우려면: ./uninstall.sh --purge"
fi

echo "완료."
