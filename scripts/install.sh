#!/bin/bash
# cc-menutor 원격 설치 스크립트
# 사용법: curl -fsSL https://raw.githubusercontent.com/Ahngbeom/cc-menutor/main/scripts/install.sh | bash
#
# 사용자 기계에서 소스를 직접 빌드하므로 코드서명·Gatekeeper 이슈가 없다.
set -euo pipefail

VERSION="1.4"
INSTALL_DIR="${HOME}/.local/share/cc-menutor"
TARBALL="https://github.com/Ahngbeom/cc-menutor/archive/refs/tags/v${VERSION}.tar.gz"

# 1. 빌드 도구(swiftc / Xcode CLT) 확인
if ! xcode-select -p >/dev/null 2>&1 || ! command -v swiftc >/dev/null 2>&1; then
  echo "⚠️  Xcode Command Line Tools가 필요합니다. 설치 창을 엽니다..."
  xcode-select --install || true
  echo "설치가 끝나면 이 명령을 다시 실행하세요."
  exit 1
fi

# 2. 소스 다운로드 (안정 위치에 풀기 — LaunchAgent plist가 절대경로를 참조)
echo "⬇️  소스 다운로드 (v${VERSION})..."
mkdir -p "$INSTALL_DIR"
curl -fsSL "$TARBALL" | tar -xz -C "$INSTALL_DIR" --strip-components=1

# 3. 빌드 + LaunchAgent 등록 (기존 setup.sh 재사용: build.sh + install.sh)
cd "$INSTALL_DIR"
./setup.sh

echo ""
echo "✅ 완료! 메뉴바에서 ⌨ 아이콘을 확인하세요."
echo "   제거: curl -fsSL https://raw.githubusercontent.com/Ahngbeom/cc-menutor/main/scripts/uninstall.sh | bash"
