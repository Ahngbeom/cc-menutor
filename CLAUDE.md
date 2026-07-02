# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 프로젝트 개요

macOS 메뉴바에서 Claude Code의 5시간 블록 사용량(토큰·비용)을 보여주는 **단일 파일 네이티브 Swift 앱**. 전체 로직이 `ClaudeMonitor.swift` 하나에 들어 있고, 나머지는 빌드/설치 셸 스크립트다. Xcode 프로젝트나 SwiftPM 매니페스트는 없다.

## 명령어

```bash
./build.sh        # swiftc -O -framework Cocoa 로 단일 파일 컴파일 (캐시: /tmp/swiftmodulecache) → ./cc-menutor
./cc-menutor      # 포그라운드 실행 (Dock 미표시 accessory 앱) — 동작 확인용
./install.sh      # LaunchAgent(io.github.ahngbeom.cc-menutor.plist) 생성·로드 → 로그인 시 자동 시작
./setup.sh        # build + install 한 번에
./uninstall.sh    # LaunchAgent 언로드·제거
tail -f ~/.cc-menutor.log   # LaunchAgent 실행 시 stdout/stderr 로그
```

테스트 프레임워크·린터·패키지 매니저는 없다. **검증은 `./build.sh` 성공 + `./cc-menutor` 수동 실행으로 메뉴바 동작을 직접 확인**하는 것이 전부다.

요구사항: macOS 12+, Xcode Command Line Tools(`swiftc`), 데이터 소스를 만드는 Claude Code CLI.

## 아키텍처

`ClaudeMonitor.swift` 한 파일이지만 데이터 흐름은 4단계로 나뉜다:

1. **데이터 소스** — `UsageDataReader.readAll()`이 `~/.claude/projects/`를 재귀 순회하며 `.jsonl`을 읽는다. `type=="assistant"` 라인만 파싱하고, `uuid`로 중복 제거하며, ISO8601(소수초 유무 둘 다) 타임스탬프를 처리한다. 외부 전송 없는 완전 오프라인.
2. **가격/비용** — `PRICING` 패턴 테이블 + `getPricing(for:)`(부분 문자열 매칭, 미매칭 시 `DEFAULT_PRICING`=Sonnet 단가). `UsageEntry.cost`가 input/output/cacheRead/cacheWrite 4종 토큰으로 비용을 산출한다.
3. **집계** — `UsageStats`가 entry 배열을 받아 합계·모델별 breakdown을 계산. `FiveHourBlock.active(from:now:)`는 **부동 앵커** 도메인 로직이다: 유휴(>5시간 공백) 후 첫 활동 시각을 UTC 정시로 내림한 지점에서 시작해 5시간 윈도우를 +5h씩 체인한다(고정 00/05/10/15/20 정렬이 **아님**). 1차(stats-cache) 경로에서는 이 계산 대신 CLI가 산출한 `startTime/endTime`을 그대로 쓴다.
4. **UI** — `ClaudeMonitorApp`(NSApplicationDelegate)이 30초 `Timer`로 `refresh()` → `readAll()` → `buildMenu()`를 반복한다. 메뉴바 타이틀은 현재 블록의 **output-only 토큰 + 비용**. `readAll()`은 1차/폴백 경로 여부와 무관하게 매 `refresh()`마다 항상 호출된다(파일별 증분 캐시라 실질 비용은 낮음) — 비용/토큰 집계는 여전히 stats-cache를 쓰지만, 타이틀의 "현재 모델"만은 실제 JSONL 엔트리 타임스탬프로 판별하기 때문이다(아래 참고).

## 변경 시 주의점

- **새 모델 추가·단가 변경 시 두 곳을 함께 고친다**: `PRICING`(비용)과 `shortModelName()`(표시명). 둘 다 부분 문자열 매칭이므로 더 구체적인 패턴을 앞에 둬야 한다(예: `opus-4`가 `opus`보다 먼저).
- `PRICING`/비용은 **추정값**이며 Pro/Max 플랜의 실제 청구액이 아니다. 비용 로직을 바꿔도 이 전제를 유지한다.
- **비용 소스는 2경로다**: 1차는 `stats-cache.json`(CLI 실측 `costUSD`), 폴백은 JSONL+`PRICING`(추정). 두 숫자는 분기할 수 있으며, 폴백 진입 시 메뉴 상단에 "추정 모드" 헤더로 사용자에게 고지한다(`buildMenuFromEntries`). 단가 로직 수정은 폴백에만 영향, 1차 경로는 CLI가 계산한다.
- **타이틀의 "현재 모델"은 stats-cache의 `models` 배열 순서를 신뢰하지 않는다**: 이 배열은 CLI가 모델을 처음 발견한 순서일 뿐 최근 사용순이 아니다(예: 다른 프로젝트 창에서 먼저 쓴 모델이 배열 끝에 올 수 있음). `updateStatusBarTitle(fromCache:)`는 대신 `cachedAll`(JSONL, 타임스탬프 오름차순)을 블록 구간으로 필터링해 마지막 엔트리의 모델을 쓰고, 매칭 실패 시에만 `b.models.last`로 폴백한다.
- LaunchAgent plist는 `install.sh`가 바이너리 **절대경로를 박아** 생성한다. 바이너리 위치를 옮기면 재설치 필요.
- **바이너리/프로세스명은 `cc-menutor`** (구버전 `ClaudeMonitor`에서 리브랜딩). 번들 ID 없는 bare 실행 파일이라
  `UserDefaults.standard` 도메인이 바이너리명에서 자동 파생되므로, 바이너리명을 다시 바꾸면 설정 도메인도 같이
  바뀐다 — `migrateLegacyDefaultsIfNeeded()`가 앱 시작 시 1회 구 도메인(`~/Library/Preferences/ClaudeMonitor.plist`)에서
  값을 복사해 기존 사용자 설정이 사라진 것처럼 보이지 않게 한다. `install.sh`도 구버전
  `io.github.ahngbeom.claude-monitor` LaunchAgent를 자동 정리한다.
- 사용자 조정 지점은 README "커스터마이징" 섹션 참고: `PRICING` 단가, 30초 `Timer` 간격, `FiveHourBlock.active()` 윈도우 계산.
- **5시간 사용 블록 ≠ 서버 rate-limit 리셋**: 이 앱의 블록은 메시지 타임스탬프 기반 **부동(첫 활동 기준)** 윈도우다. Claude Code의 "한도 90% 근접, X시 리셋" 경고는 서버 응답 헤더 기반 롤링 윈도우라 기준·리셋 시각이 다르며, 그 값은 로컬에 저장되지 않는다. 두 개념을 혼동하지 말 것.
- **릴리스(`gh release create`) 시 GitHub Actions(`.github/workflows/bump-homebrew-formula.yml`)가 `Ahngbeom/homebrew-tap`의 `Formula/cc-menutor.rb`를 자동 갱신한다**(`mislav/bump-homebrew-formula-action`, 커밋 SHA로 고정). 다른 저장소에 쓰기 때문에 `HOMEBREW_TAP_TOKEN`(fine-grained PAT, `homebrew-tap`에 Contents R/W) 시크릿이 필요 — 이게 만료·누락되면 이 단계만 조용히 실패할 수 있으니 릴리스 후 `gh run list --repo Ahngbeom/cc-menutor --workflow "Update Homebrew formula"`로 확인할 것.
