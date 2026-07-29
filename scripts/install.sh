#!/bin/bash
# cc-menutor 원격 설치 스크립트
# 사용법: curl -fsSL https://raw.githubusercontent.com/Ahngbeom/cc-menutor/main/scripts/install.sh | bash
#
# 사용자 기계에서 소스를 직접 빌드하므로 코드서명·Gatekeeper 이슈가 없다.
set -euo pipefail

INSTALL_DIR="${HOME}/.local/share/cc-menutor"
REPO="Ahngbeom/cc-menutor"

# 설치할 버전은 GitHub의 "최신 릴리스"에서 가져온다. 예전엔 이 파일에 VERSION을 하드코딩했는데,
# 릴리스 때 ClaudeMonitor.swift의 APP_VERSION만 올리고 여기를 잊으면 이 스크립트가 조용히
# 구버전을 설치했다(실제로 v1.11 시점에 1.10이 박혀 있었다). 설치 스크립트가 자기가 설치할
# 저장소 안에 살면서 자기 버전을 고정하는 구조 자체가 드리프트를 부르므로 고정을 없앤다.
# 특정 버전을 설치하려면: CC_MENUTOR_VERSION=1.11 curl ... | bash
VERSION="${CC_MENUTOR_VERSION:-}"
if [ -z "$VERSION" ]; then
  echo "🔎 최신 릴리스 확인 중..."
  VERSION="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' | head -1)"
fi
if [ -z "$VERSION" ]; then
  echo "❌ 최신 릴리스를 확인하지 못했습니다(네트워크 또는 GitHub API 문제)."
  echo "   버전을 직접 지정해 다시 시도하세요: CC_MENUTOR_VERSION=1.11 curl -fsSL ... | bash"
  exit 1
fi
TARBALL="https://github.com/${REPO}/archive/refs/tags/v${VERSION}.tar.gz"

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
