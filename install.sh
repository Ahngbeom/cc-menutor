#!/bin/bash
# cc-menutor install script
# 빌드 후 LaunchAgent로 등록하여 로그인 시 자동 시작

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY="$SCRIPT_DIR/cc-menutor"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_NAME="io.github.ahngbeom.cc-menutor.plist"
PLIST_DST="$LAUNCH_AGENTS_DIR/$PLIST_NAME"

# 구버전(ClaudeMonitor) LaunchAgent 식별자 — 리브랜딩 이전 설치 잔존분 정리용
OLD_LABEL="io.github.ahngbeom.claude-monitor"
OLD_PLIST="$LAUNCH_AGENTS_DIR/${OLD_LABEL}.plist"

# 1. 빌드 확인
if [ ! -f "$BINARY" ]; then
  echo "바이너리가 없습니다. 먼저 빌드하세요:"
  echo "  ./build.sh"
  exit 1
fi

# 2. 구버전(claude-monitor) LaunchAgent 정리 — 사라진 바이너리 경로를 계속 참조하며
#    로그인마다 실패하는 stale 항목이 남지 않도록 새 Label 등록 전에 먼저 정리한다.
if [ -f "$OLD_PLIST" ]; then
  launchctl bootout "gui/$(id -u)/$OLD_LABEL" 2>/dev/null || launchctl unload "$OLD_PLIST" 2>/dev/null || true
  rm -f "$OLD_PLIST"
  echo "🔄 구버전(claude-monitor) LaunchAgent 정리됨"
fi

# 3. LaunchAgents 디렉토리 생성
mkdir -p "$LAUNCH_AGENTS_DIR"

# 4. plist 생성 (바이너리 경로 반영)
cat > "$PLIST_DST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>io.github.ahngbeom.cc-menutor</string>

    <key>ProgramArguments</key>
    <array>
        <string>${BINARY}</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>

    <key>StandardErrorPath</key>
    <string>${HOME}/.cc-menutor.log</string>

    <key>StandardOutPath</key>
    <string>${HOME}/.cc-menutor.log</string>
</dict>
</plist>
EOF

echo "✅ LaunchAgent 등록: $PLIST_DST"

# 5. 기존 서비스 종료 (있으면)
launchctl unload "$PLIST_DST" 2>/dev/null && echo "   기존 서비스 중지됨" || true

# 6. 새 서비스 시작
launchctl load "$PLIST_DST"
echo "✅ 서비스 시작됨"
echo ""
echo "메뉴바에 ⌨ 아이콘이 나타납니다."
echo ""
echo "로그 확인:  tail -f ~/.cc-menutor.log"
echo "서비스 중지: ./uninstall.sh"
