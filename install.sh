#!/bin/bash
# claude-monitor install script
# 빌드 후 LaunchAgent로 등록하여 로그인 시 자동 시작

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY="$SCRIPT_DIR/ClaudeMonitor"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_NAME="io.github.ahngbeom.claude-monitor.plist"
PLIST_DST="$LAUNCH_AGENTS_DIR/$PLIST_NAME"

# 1. 빌드 확인
if [ ! -f "$BINARY" ]; then
  echo "바이너리가 없습니다. 먼저 빌드하세요:"
  echo "  ./build.sh"
  exit 1
fi

# 2. LaunchAgents 디렉토리 생성
mkdir -p "$LAUNCH_AGENTS_DIR"

# 3. plist 생성 (바이너리 경로 반영)
cat > "$PLIST_DST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>io.github.ahngbeom.claude-monitor</string>

    <key>ProgramArguments</key>
    <array>
        <string>${BINARY}</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>StandardErrorPath</key>
    <string>${HOME}/.claude-monitor.log</string>

    <key>StandardOutPath</key>
    <string>${HOME}/.claude-monitor.log</string>
</dict>
</plist>
EOF

echo "✅ LaunchAgent 등록: $PLIST_DST"

# 4. 기존 서비스 종료 (있으면)
launchctl unload "$PLIST_DST" 2>/dev/null && echo "   기존 서비스 중지됨" || true

# 5. 새 서비스 시작
launchctl load "$PLIST_DST"
echo "✅ 서비스 시작됨"
echo ""
echo "메뉴바에 ⌨ 아이콘이 나타납니다."
echo ""
echo "로그 확인:  tail -f ~/.claude-monitor.log"
echo "서비스 중지: ./uninstall.sh"
