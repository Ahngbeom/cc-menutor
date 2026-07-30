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

1. **데이터 소스** — `UsageDataReader.readAll()`이 `~/.claude/projects/`를 재귀 순회하며 `.jsonl`을 읽는다. `type=="assistant"` 라인만 파싱하고(단, `SYNTHETIC_MODEL_NAMES` = rate-limit 거부 응답의 `<synthetic>`은 실사용이 아니므로 제외), `dedupeKey`(`message.id`+`requestId` 우선, 없으면 `uuid`)로 중복 제거하며, ISO8601(소수초 유무 둘 다) 타임스탬프를 처리한다. **사용량 데이터는 완전 오프라인** — 앱의 유일한 아웃바운드 요청은 표시 통화가 「원화」일 때의 환율 조회(`ExchangeRateFetcher`)뿐이며, 그 요청도 사용량 정보를 담지 않는다(아래 "원화 환산" 항목 참고).
2. **가격/비용** — `parseModelVersion()`이 모델 ID를 `(family, major, minor)`로 정규화하고, `getPricing(for:at:)`이 `VERSIONED_PRICING` 딕셔너리를 조회한다. 미등록 버전은 `FAMILY_PRICING`(해당 family의 **현행** 단가), family도 미상이면 `DEFAULT_PRICING`으로 폴백하며 둘 다 `matched=false`라 "⚠ 미상 모델" 배너로 고지된다. `UsageEntry.cost`는 init에서 1회 계산해 저장하는 프로퍼티다(computed였을 때 전 생애 엔트리를 매 refresh마다 재계산해 메인 스레드 최대 CPU 소비원이었음).
3. **집계** — `UsageStats`가 entry 배열을 받아 합계·모델별 breakdown을 계산. `FiveHourBlock.active(from:now:)`는 **부동 앵커** 도메인 로직이다: 유휴(>5시간 공백) 후 첫 활동 시각을 UTC 정시로 내림한 지점에서 시작해 5시간 윈도우를 +5h씩 체인한다(고정 00/05/10/15/20 정렬이 **아님**). 1차(stats-cache) 경로에서는 이 계산 대신 CLI가 산출한 `startTime/endTime`을 그대로 쓴다.
4. **UI** — `ClaudeMonitorApp`(NSApplicationDelegate)이 30초 `Timer`로 `refresh()` → `readAll()` → `buildMenu()`를 반복한다. 메뉴바 타이틀은 현재 블록의 **output-only 토큰 + 비용**. `readAll()`은 1차/폴백 경로 여부와 무관하게 매 `refresh()`마다 항상 호출된다(파일별 증분 캐시라 실질 비용은 낮음) — 비용/토큰 집계는 여전히 stats-cache를 쓰지만, 타이틀의 "현재 모델"만은 실제 JSONL 엔트리에서 토큰 수 기준으로 가장 많이 쓴 모델로 판별하기 때문이다(아래 참고).

## 변경 시 주의점

- **새 모델 추가 시**: `VERSIONED_PRICING`에 `ModelVersionKey(family:major:minor:)` 항목을 추가하면 비용과 표시명(`shortModelName()`)이 **함께** 따라온다 — 둘 다 `parseModelVersion()` 결과를 공유하기 때문이다. 새 family(예: 미래의 `fable` 계열)라면 `MODEL_FAMILIES`와 `FAMILY_PRICING`에도 추가한다. 캐시 단가는 input에서 공식 배수로 파생되므로 input/output만 넣으면 된다.
  - **순서 의존이 없다**(딕셔너리 조회). 예전엔 `[(pattern, pricing)]` 배열을 `contains`로 훑어서 "구체적인 패턴을 앞에" 규칙을 지켜야 했는데, 실제 모델 ID가 신형(`claude-haiku-4-5`)과 구형(`claude-3-5-haiku`) 두 표기를 오간다는 걸 놓쳐 `haiku-3-5`/`sonnet-3-5`/`sonnet-3-7` 패턴이 **어디에도 매칭되지 않는 죽은 코드**가 됐고, 모든 Haiku가 포괄 패턴으로 떨어져 Haiku 4.5가 4배 과소 청구됐다(게다가 `matched=true`라 경고도 안 떴다). `FAMILY_PRICING`이 은퇴 티어를 가리켜 Opus 5는 3배 과대 추정됐다. **family 폴백은 반드시 현행 티어를 가리켜야 한다.**
  - 회귀 가드: 셀프테스트의 `officialPrices` 표가 실제 모델 ID → 공식 단가를 직접 대조한다. 단가를 바꿀 땐 이 표도 같이 고친다.
- `PRICING`/비용은 **추정값**이며 Pro/Max 플랜의 실제 청구액이 아니다. 비용 로직을 바꿔도 이 전제를 유지한다.
- **비용 소스는 2경로다**: 1차는 `stats-cache.json`(CLI 실측 `costUSD`), 폴백은 JSONL+`PRICING`(추정). 두 숫자는 분기할 수 있으며, 폴백 진입 시 메뉴 상단에 "추정 모드" 헤더로 사용자에게 고지한다(`buildMenuFromEntries`). 단가 로직 수정은 폴백에만 영향, 1차 경로는 CLI가 계산한다.
- **타이틀의 "현재 모델"은 "최근 사용 모델"이 아니라 "(현재 5시간 블록 내) 토큰 수 기준 최다 사용 모델"이다**: stats-cache의 `models` 배열 순서는 신뢰하지 않는다(CLI가 모델을 처음 발견한 순서일 뿐 사용량 순이 아니다). 순수 함수 `mostUsedModel(in:)`이 블록 구간 엔트리를 **원본** 모델 문자열 기준으로 그룹핑해 토큰 합(input+output+cacheRead+cacheWrite)이 가장 큰 모델을 고르며, 동점이면 모델 문자열 알파벳순으로 결정론적으로 선택한다. `updateStatusBarTitle(fromCache:)`/`updateStatusBarTitleFromEntries()` 둘 다 이 함수를 공유한다. 전자는 `cachedAll`(JSONL)을 블록 구간(`b.startTime`~`b.endTime`)으로 필터링해 넘기고, 타임스탬프 파싱 실패 등 예외 상황에서만 `b.models.last`로 폴백한다. `mostUsedModel()`은 (`UsageStats.modelBreakdown`과 달리) `shortModelName()`으로 미리 축약하지 않은 원본 문자열을 반환하므로, `TitleContext.model`의 "축약 전 원본 문자열" 계약이 유지되고 `shortModelName()` 적용은 항상 렌더링 시점(`buildTitleParts()`) 한 번으로 끝난다(이중 축약 방지).
- **"yyyy-MM-dd" 날짜 키는 반드시 `gregorianDayString()`/`gregorianDayFormatter()`를 쓴다** — 맨손 `DateFormatter`는 금지다. `DateFormatter`는 지정하지 않으면 `Locale.current`, 따라서 **사용자의 달력 체계**를 따라가서 시스템 설정이 불교력(태국)이면 같은 순간이 `"2569-07-29"`로 찍힌다. 이 앱에서 이 문자열은 표시용이 아니라 **데이터 키**다: ① CLI가 `stats-cache.json`에 쓴 그레고리력 키와 비교(`StatsCache.todayPeriod()`)하거나 ② UserDefaults에 영속화해 나중에 다시 파싱(`localDayString`/`daysBetween` → `gamLastActiveDay`)한다. 예전엔 세 곳 다 맨손 포매터를 써서 불교력 사용자의 드롭다운 "오늘" 섹션이 **영구히 0**이었고(1차·UTC 폴백 둘 다 빗나감 — 폴백이 같은 포매터의 timeZone만 바꿔 재사용했기 때문), 스트릭 키는 달력 설정을 바꾸면 깨졌다.
  - 반대로 **표시용은 로케일을 따라가는 게 맞다** — `formatTimeShort`는 손대지 말 것. `ISO8601DateFormatter`(`parseISO8601`)는 정의상 그레고리력·POSIX 고정이라 애초에 안전하다.
  - 회귀 가드: 셀프테스트의 stats-cache 픽스처는 **그레고리력으로 하드코딩**해 만든다. 예전엔 픽스처를 프로덕션과 똑같은 결함 포매터로 만들어 양쪽이 나란히 틀리는 바람에 **테스트는 통과하고 프로덕션만 깨지는** 자기충족적 테스트였다. 검증은 `./cc-menutor --test -AppleLocale "th_TH@calendar=buddhist"` 로 실제 달력을 바꿔 돌린다.
- **`NumberFormatter`도 위와 같은 계열의 함정이다 — `formatKRW()`는 로케일과 그룹핑을 *둘 다* 명시한다.** `NumberFormatter`는 지정하지 않으면 `Locale.current`를 따라가 `de_DE`에선 천단위 구분자가 `.`(`₩6.623`), 인도 계열 로케일에선 3-2-2 그룹핑(`₩6,62,300`)이 된다. 그런데 `Locale(identifier: "en_US_POSIX")`만 지정하면 **POSIX 관례상 `usesGroupingSeparator == false`/`groupingSize == 0`이라 구분자가 통째로 사라져** `₩6623`이 된다(로케일만 고정하면 고쳐진다고 착각하기 쉬운 지점 — 실제로 셀프테스트가 이 상태를 잡아냈다). 그래서 로케일로 나머지 동작을 못박고 `usesGroupingSeparator`/`groupingSeparator`/`groupingSize`는 직접 지정한다. 기존 `formatCost`가 `String(format:)`으로 애초에 로케일 무관인 것과도 일관돼야 한다.
  - 회귀 가드: `./cc-menutor --test -AppleLocale "de_DE"`, `-AppleLocale "hi_IN"` 으로 돌린다(위 불교력 검증과 같은 방식). 셀프테스트에 "`.`을 쓰지 않는다"·"3자리 그룹핑 고정" 단정이 있다.
- **원화 환산(`DisplayCurrency`/`CurrencyContext`/`krwDisplay`)**: 비용 표기 통화는 사용자가 메뉴 `💱 표시 통화`에서 고르며 기본값은 `.usd`다. **이 기본값은 의도적이다** — 환율 조회가 이 앱의 유일한 아웃바운드 요청이므로, `.krw`를 고른 사용자만 네트워크를 타게 해서 "달러 표시 = 완전 오프라인"을 유지한다(`maybeFetchExchangeRate()`의 첫 `guard`가 그 한 줄이다). 메뉴바는 **택일**(`formatMoney`), 드롭다운은 주요 합계 3곳만 **병기**(`krwSuffix` — 현재 블록·오늘·전체 누적)이고 모델별 분해·소모율·기록 섹션은 달러로 남긴다.
  - **타이틀과 드롭다운은 반드시 같은 판정을 공유해야 한다.** 순수 함수 `currencyContext(currency:rate:)`가 유일한 판정자이고 `krwDisplay(currency:rate:now:)`가 드롭다운 상태 4종(병기/기준일/stale/unavailable)을 만든다. 두 `makeBlockDisplayData` 어댑터와 두 `makeTitleContext` 경로가 이것들만 쓴다. 원화 문자열도 `formatKRW(usd * rate)` 한 곳으로 수렴한다(`formatMoney`/`krwSuffix` 둘 다). 리셋 앵커에서 "드롭다운만 고치고 타이틀을 놓쳐 위아래가 다른 값을 보여준" 버그를 그대로 반복하지 않기 위한 구조이며, 셀프테스트가 "타이틀 원화 == 드롭다운 병기 원화"를 직접 단정한다.
  - **경고 임계값(`BLOCK_COST_BUDGET`)은 USD로 남긴다.** 환율에 연동하면 사용량이 그대로인데 환율이 움직여서 경고 색이 바뀌는, 설명 불가능한 동작이 된다.
  - `currencyContext()`는 환율이 없거나 `isPlausibleKRWRate()`를 통과하지 못하면 **무조건 `.usd`로 떨어진다**. `0`이나 `NaN`이 통과하면 모든 비용이 `₩0`으로 렌더돼 "무료"로 오독되므로, 파싱(`parseExchangeRateResponse`)·저장(`ExchangeRateStore.load`)·표시 세 단계 모두에 이 방어선이 있다. `ExchangeRateStore.load`가 `double(forKey:)` 대신 `object(forKey:) as? Double`을 쓰는 것도 같은 이유다(전자는 키가 없을 때 `0`을 돌려줘 "저장 안 됨"과 구분이 안 된다).
  - `TitleContext.currency`/`BlockDisplayData.krw`는 **기본값이 있는 필드로 추가**됐다(각 구조체의 손으로 쓴 init 규약). 덕분에 `$`를 하드코딩한 기존 타이틀 셀프테스트들이 수정 없이 통과하며, **그 통과 자체가 "기존 사용자 화면 불변" 회귀 가드**다. `BlockDisplayData.asLoadingSkeleton()`에도 `krw`를 전파해야 한다 — 빠뜨리면 메뉴가 열린 채 새로고침될 때 원화 병기가 한 프레임 사라져 행 폭이 흔들린다.
  - 조회 스케줄링은 `refresh()`의 메인 큐 완료 지점에 편승하되 파이프라인을 블로킹하지 않는다(`URLSession`은 비동기라 `.utility` 블록에 동기로 끼울 수 없다). 성공 시 1시간, **실패 시 5분 백오프**가 필수다 — 없으면 새로고침 주기 10초를 쓰는 오프라인 사용자가 분당 6회 실패 요청을 낸다. 실패 시 `cachedExchangeRate`는 손대지 않는다(`StatsCacheReader`의 "디코드 실패 시 캐시 오염 방지"와 같은 원칙).
  - stale 배너는 `baseDate`가 아니라 `fetchedAt` 기준으로 판단한다 — ECB 환율은 주말·공휴일에 **정상적으로** 직전 영업일 값이라, `baseDate`로 판단하면 주말마다 거짓 경고가 뜬다.
  - 셀프테스트가 `.standard`를 건드릴 때는 `CurrencySettings.currency()`가 아니라 `object(forKey: "displayCurrency")`로 백업한다 — 전자는 "키 없음"과 "usd 저장됨"을 구분할 수 없어 복원 시 없던 키를 만들어내 **사용자 도메인을 오염시킨다**(실제로 한 번 발생했다).
- LaunchAgent plist는 `install.sh`가 바이너리 **절대경로를 박아** 생성한다. 바이너리 위치를 옮기면 재설치 필요.
- **바이너리/프로세스명은 `cc-menutor`** (구버전 `ClaudeMonitor`에서 리브랜딩). 번들 ID 없는 bare 실행 파일이라
  `UserDefaults.standard` 도메인이 바이너리명에서 자동 파생되므로, 바이너리명을 다시 바꾸면 설정 도메인도 같이
  바뀐다 — `migrateLegacyDefaultsIfNeeded()`가 앱 시작 시 1회 구 도메인(`~/Library/Preferences/ClaudeMonitor.plist`)에서
  값을 복사해 기존 사용자 설정이 사라진 것처럼 보이지 않게 한다. `install.sh`도 구버전
  `io.github.ahngbeom.claude-monitor` LaunchAgent를 자동 정리한다.
- 사용자 조정 지점은 README "커스터마이징" 섹션 참고: `PRICING` 단가, 30초 `Timer` 간격, `FiveHourBlock.active()` 윈도우 계산.
- **5시간 사용 블록 ≠ 서버 rate-limit 리셋**: 이 앱의 블록은 메시지 타임스탬프 기반 **부동(첫 활동 기준)** 윈도우다. Claude Code의 "한도 90% 근접, X시 리셋" 경고는 서버 응답 헤더 기반 롤링 윈도우라 기준·리셋 시각이 다르며, 그 값은 로컬에 저장되지 않는다. 두 개념을 혼동하지 말 것.
- **리셋 기준 시각 보정(`ResetAnchorSettings`/`FiveHourBlock.anchoredWindow`)**: 위 문제(로컬 블록 ≠ 서버 진짜 리셋)를 사용자가 직접 메꾸는 기능이다. 사용자가 메뉴 "⚓ 리셋 기준 시각"에 입력한 절대 순간을 `resetAnchorInstant`(UserDefaults, epoch seconds)로 영구 저장하고, `FiveHourBlock.anchoredWindow(containing:anchor:)`가 순수 절대시각 산술(`anchor + 5h × n`, 타임존/DST 무관)로 그 순간부터 반복되는 그리드를 계산한다. 폴백(JSONL) 경로는 `FiveHourBlock.active(from:now:anchor:)`가 새 블록 시작점을 앵커 그리드에 스냅해 표시와 집계 필터링 모두 일관됐고(변경 없음), **1차(stats-cache) 경로도 이제 그렇다** — 원래는 앵커가 표시 윈도우 라벨만 바꾸고 토큰/비용은 여전히 CLI의 "자연" 블록(`b.tokenCounts`/`costUSD`, 첫 활동 기준 floor 같은 휴리스틱)을 그대로 썼는데, 이게 "의도된 절충"이 아니라 **실제 버그**였다 — 유휴 후 재개 시 CLI 휴리스틱 블록이 앵커 그리드와 어긋나면 라벨(예: "08:00→13:00")과 그 아래 숫자가 서로 다른 구간을 가리켜 "블록이 섞인 것처럼" 보였다. `makeBlockDisplayData(fromCache:)`는 이제 앵커가 활성화돼 있으면 `cachedAll`(JSONL)을 앵커 창으로 필터링해 `UsageStats`로 재계산한 값(`anchorStats`)을 쓴다 — **그리고 메뉴바 타이틀(`makeTitleContext`/`updateStatusBarTitle`)도 마찬가지다.** 원래는 드롭다운만 고치고 타이틀을 놓쳐서 같은 블록인데 메뉴바와 드롭다운이 서로 다른 토큰·비용을 보여주고 경고 색까지 엇갈렸다(타이틀은 주황인데 드롭다운은 40%). 지금은 두 어댑터가 순수 함수 `anchoredWindowStats(cachedAll:now:anchor:)` 하나를 공유하므로 각자 계산하다 어긋날 수 없고, 셀프테스트가 "타이틀 숫자 == 드롭다운 숫자"를 직접 단정한다. 타이틀 경로를 `makeTitleContext`(순수 계산)와 `updateStatusBarTitle`(렌더링)로 나눈 것도 이 때문이다 — 후자는 `statusItem` 강제 언랩에 의존해 셀프테스트가 호출할 수 없다 — 토큰 수는 JSONL 원본이라 여전히 정확하고, 비용만 CLI의 정확한 `costUSD` 대신 `PRICING` 기반 추정치가 된다(`BlockDisplayData.anchorIsEstimating`이 이때 true → "⚓ 리셋 앵커 적용 중 — 비용 추정치" 배너). 앵커 미설정 시엔 완전히 예전 그대로(CLI `costUSD` 그대로). "오늘"/"전체 누적" 섹션(`stats.todayPeriod()`/`stats.cumulative`)은 앵커와 무관한 별개 집계라 이 변경의 영향을 받지 않는다. 앵커는 1회성이 아니라 사용자가 지우기 전까지 유지되며, 유휴 후 서버 재시작 시점이 앵커 위상과 다시 어긋나면 사용자가 재입력해야 한다 — **단, `~/.claude/rate-limits-cache.json`(선택적 3차 소스, 아래 항목 참고)이 신선하면 자동으로 재보정된다.** 그 파일이 없거나 stale이면 여전히 수동 재입력 외엔 방법이 없다(서버 응답 헤더 값은 API 요청 때만 오고 로컬에 저장되지 않으므로).
- **리셋 앵커 자동 동기화(`RateLimitsCacheReader`/`autoResetAnchor`/`ResetAnchorSettings.autoSyncEnabled`)**: 위 "재입력해야 한다"는 한계를 부분적으로 메꾸는 선택적 기능이다. Claude Code CLI는 statusLine 스크립트 stdin JSON에 `rate_limits.five_hour`/`seven_day`(서버 실측 `used_percentage`/`resets_at`, Claude.ai Pro/Max 구독자 한정)를 전달하지만 디스크엔 저장하지 않는다 — 이 앱은 그 값을 직접 얻지 않고, 사용자의 statusLine 스크립트가 `rate_limits` 객체를 그대로 `~/.claude/rate-limits-cache.json`에 떨궈 두는 것을 **읽기만** 한다(쓰기 쪽은 이 저장소 범위 밖 — README "리셋 기준 시각 보정" 참고). `refresh(manual:)`이 매 사이클 `RateLimitsCacheReader.load()`를 호출하고, `autoResetAnchor(from:now:)`(순수 함수)가 `five_hour.resetsAt`이 아직 미래(신선)면 그 값을 그대로 앵커 후보로 반환한다(anchoredWindow는 절대시각 산술이라 "다음 리셋 시각"을 앵커로 써도 "현재 윈도우 시작 시각"을 써도 동일한 그리드가 나오므로 5시간을 빼는 보정이 불필요). `ResetAnchorSettings.autoSyncEnabled()`(기본 true)가 켜져 있고 값이 실제로 달라질 때만 `setAnchor()`가 호출된다. `openResetAnchorAlert`는 **"지우기"든 수동 입력이든 `autoSyncEnabled`를 함께 끈다** — 그렇지 않으면 다음 refresh 때 신선한 캐시가 즉시 앵커를 재적용해 사용자 의도를 무시한다("지우기"는 무시되고, 수동 입력은 30초 만에 덮어써져 상태 라벨이 "수동 입력됨"→"자동 보정됨"으로 바뀌며 수동 앵커를 아예 유지할 수 없었다 — 지우기 경로에만 이 처리가 있고 입력 경로엔 빠져 있던 버그). 메뉴의 "서버 실측으로 자동 보정" 체크박스로 다시 켤 수 있다. `seven_day`(주간)도 이제 표시된다 — `makeServerLimitsSection(from:now:)`(순수 함수)이 신선한 창만 골라 `BlockDisplayData.serverLimits`에 담고, 드롭다운의 `🎯 서버 실측 사용률` 섹션이 5시간/주간을 각각 `%`와 리셋까지 남은 시간으로 렌더한다. 이 값은 앱이 토큰을 세어 만든 추정치가 아니라 **서버가 계산한 실측치**라, 5시간 블록 섹션(추정)과는 기준도 리셋 시각도 다르다 — 그래서 별도 섹션으로 나란히 두고 라벨로 구분한다. 파일이 없거나 stale이면 `serverLimits`가 nil이라 섹션 자체가 사라진다(기존 사용자 화면 불변). 오랫동안 `usedPercentage`의 유일한 소비처가 `rateLimitResetIfExceeded()`의 `>= 100` 비교였고 `sevenDay`는 읽는 코드가 아예 없었다.
- **릴리스(`gh release create`) 시 GitHub Actions(`.github/workflows/bump-homebrew-formula.yml`)가 `Ahngbeom/homebrew-tap`의 `Formula/cc-menutor.rb`를 자동 갱신한다.** 다른 저장소에 쓰기 때문에 `HOMEBREW_TAP_TOKEN`(`homebrew-tap`에 대한 쓰기 권한이 있는 PAT — fine-grained면 Contents R/W, classic이면 `repo` 스코프) 시크릿이 필요 — 만료·누락되면 이 단계만 조용히 실패할 수 있으니 릴리스 후 `gh run list --repo Ahngbeom/cc-menutor --workflow "Update Homebrew formula"`로 확인할 것.
  - **v1.4 릴리스 때 겪은 이력**: 원래 `mislav/bump-homebrew-formula-action`(서드파티, 커밋 SHA 고정)을 썼으나, 이 액션이 체크섬 계산 시 사용하는 GitHub tarball API가 2026-05-16경부터 302 대신 303을 반환하도록 바뀌면서 `Error: unexpected HTTP 303 response`로 깨졌다(액션 쪽 미해결 버그, 토큰 종류와 무관 — [issue #340](https://github.com/mislav/bump-homebrew-formula-action/issues/340)). 토큰 재발급으로는 해결되지 않아, 워크플로를 서드파티 액션 없이 **인라인 `curl -fsSL` + `git push`**로 대체했다 — formula의 `url` 필드가 가리키는 바로 그 공개 다운로드 URL(`archive/refs/tags/vX.Y.tar.gz`, `scripts/install.sh`와 동일)을 직접 받아 해시하므로 문제의 tarball-API HEAD 요청 자체를 타지 않는다.
