# Claude Code Usage Monitor

macOS 메뉴바에서 Claude Code 5시간 블록 사용량을 실시간으로 확인하는 네이티브 Swift 앱.

> **⚠️ 비공식 프로젝트** — 커뮤니티가 만든 유틸리티이며 **Anthropic PBC와 무관**합니다(제작·후원·보증 관계 없음).
> "Claude"·"Claude Code"는 Anthropic PBC의 상표이며, 이 앱이 읽는 로컬 사용량 데이터를 식별하기 위해 **설명 목적으로만** 사용합니다.

```
메뉴바 표시 예시:
  ⌨ 42.3K $0.18
```

## 기능

- **5시간 블록** — Claude Code가 산출한 활성 블록의 진행률·리셋까지 남은 시간·소모율(burn rate)
- **모델별 breakdown** — Opus / Sonnet / Haiku 각각의 토큰 및 비용 (버전 자동 인식)
- **오늘 통계** — 당일(로컬 기준) 토큰·비용·모델별 분해
- **전체 누적** — 기록된 전체 사용량
- **30초 자동 갱신** — 백그라운드 처리, 파일 변경 시에만 재읽기

메뉴바 타이틀은 `⌨ <블록 output 토큰> <비용>` 형식이며, 최근 5시간 내 활동이
없으면 `⌨ idle` 로 표시됩니다.

## 데이터 소스

1차로 **Claude Code CLI가 직접 유지하는 `~/.claude/stats-cache.json`**(CLI가 쓰는 권위 있는
실시간 집계 — 비용 `costUSD`·5시간 블록·일/주/월 통계)을 읽습니다.
이 파일이 없는 구버전 CLI에서는 **`~/.claude/projects/**/*.jsonl`** 직접 파싱으로 폴백합니다.

외부 서버 전송 없음, 완전 오프라인.

> ⚠️ 두 파일 모두 Claude Code CLI가 유지하는 **비공식 내부 포맷**입니다. CLI 업데이트로 스키마가
> 바뀌면 1차 경로가 실패할 수 있으나, 그때는 JSONL 폴백(추정 모드)으로 자동 전환됩니다.

## 프라이버시 & 보안

이 앱은 **로컬에서만** 동작합니다.

- **외부 전송 0** — 네트워크 코드가 전혀 없습니다(HTTP/소켓/외부 프로세스 호출 없음). 어떤 서버로도 데이터를 보내지 않습니다.
- **대화 본문 미열람** — JSONL에서 읽는 것은 **사용량 메타데이터뿐**입니다: 타임스탬프, 모델명, 토큰 수(`message.usage`), 메시지 UUID. 프롬프트·응답 등 대화 내용은 파싱하지 않습니다.
- **읽기 전용** — `~/.claude/stats-cache.json`과 `~/.claude/projects/**/*.jsonl`을 읽기만 하며 수정하지 않습니다.
- **로컬 로그** — LaunchAgent 실행 시 stdout/stderr가 `~/.claude-monitor.log`에만 기록됩니다.

소스는 단일 파일(`ClaudeMonitor.swift`)이라 위 내용을 직접 감사할 수 있습니다.

## 요구사항

- macOS 12 Monterey 이상
- Xcode Command Line Tools (swiftc)
- Claude Code CLI (https://claude.ai/code)

## 설치

```bash
# 1. 빌드 (약 10-30초 소요)
cd ~/claude-monitor
chmod +x build.sh install.sh uninstall.sh
./build.sh

# 2. 실행 (테스트)
./ClaudeMonitor

# 3. 로그인 시 자동 시작 등록
./install.sh
```

## 제거

```bash
./uninstall.sh
```

## 5시간 블록 계산 방식

1차(stats-cache) 경로에서는 **Claude Code가 산출한 활성 블록**(`isActive`)을 그대로 사용하고,
리셋까지 남은 시간은 CLI의 `projection.remainingMinutes`를 따릅니다.

폴백(JSONL) 경로에서는 블록의 **첫 활동 시각을 UTC 정시로 내림**한 지점에서 시작해 5시간 뒤
종료하며, 직전 활동과의 공백이 5시간 이상이면 단절해 새 블록을 시작합니다.

최근 5시간 내 활동이 없으면 활성 블록이 없는 **유휴 상태**(`⌨ idle`)로 표시됩니다.

## 비용 계산

1차(stats-cache) 경로의 비용은 **Claude Code가 직접 산출한 `costUSD`**를 그대로 표시합니다(추정 아님).

폴백(JSONL) 경로에서는 아래 단가 테이블로 **추정**합니다:

| 모델 | Input | Output | Cache Read | Cache Write |
|------|-------|--------|------------|-------------|
| Claude Opus 4 | $15/M | $75/M | $1.5/M | $18.75/M |
| Claude Sonnet 4 | $3/M | $15/M | $0.30/M | $3.75/M |
| Claude Haiku 3.5 | $0.80/M | $4/M | $0.08/M | $1.00/M |

> 어느 경로든 표시 금액은 **사용량 환산 비용**이며, Pro/Max 플랜의 실제 청구액이 아닙니다.

## 사용량 경고

현재 5시간 블록 사용량이 **사용자가 정한 한도**의 일정 비율을 넘으면 메뉴바에 시각 경고가 뜹니다.

- 임계 도달 시 타이틀이 `⌨ …` → **`⚠️ <사용률>% · <리셋 남음>`** 으로 바뀌고
  색이 **주황(경고)/빨강(위험)** 으로 표시됩니다. 드롭다운 5시간 섹션에도 `사용률`·경고 줄이 추가됩니다.
- 사용률 = `max(블록 토큰 / 토큰 한도, 블록 비용 / 비용 한도)` (설정한 한도만 사용).

### 켜기 (기본은 비활성)

한도가 0이면 경고가 뜨지 않습니다. 재빌드 없이 환경변수로 켤 수 있습니다(LaunchAgent plist의
`EnvironmentVariables`에 추가하거나 셸에서 실행):

```bash
# 예: 현재 블록 토큰 1,000만 한도, 90%부터 주황, 100%부터 빨강
CLAUDE_MONITOR_TOKEN_BUDGET=10000000 \
CLAUDE_MONITOR_WARN=0.9 CLAUDE_MONITOR_CRIT=1.0 \
./ClaudeMonitor
```

| 환경변수 | 기본 | 의미 |
|----------|------|------|
| `CLAUDE_MONITOR_TOKEN_BUDGET` | 0(비활성) | 현재 블록 전체 토큰 한도 |
| `CLAUDE_MONITOR_COST_BUDGET` | 0(비활성) | 현재 블록 비용($) 한도 |
| `CLAUDE_MONITOR_WARN` | 0.90 | 경고(주황) 임계 비율 |
| `CLAUDE_MONITOR_CRIT` | 1.00 | 위험(빨강) 임계 비율 |

> **한도값 잡는 법:** 드롭다운에서 본인의 평소 블록 최대 사용량(토큰/비용)을 관찰해 그 근처로 설정하세요.

### ⚠️ Claude Code의 90% 알림과의 차이 (중요)

Claude Code 세션의 "사용량 90%" 경고는 **서버가 응답 헤더(`anthropic-ratelimit-unified-utilization`)로
내려주는 실제 사용률**이며, 한도·사용률·리셋 시각이 **로컬에 저장되지 않습니다**(API 요청 때만 옴).
따라서 API를 호출하지 않는 이 앱은 **그 진짜 %를 그대로 재현할 수 없습니다.** 본 기능은
**사용자가 정한 블록 한도 대비 근사 사용률**이라 실제 플랜 한도와 다를 수 있습니다. 진짜 %를 원하면
OAuth 토큰으로 직접 API를 호출해야 하나, 비공식 엔드포인트·ToS 위험 때문에 채택하지 않았습니다.

## 로그

```bash
tail -f ~/.claude-monitor.log
```

## 커스터마이징

`ClaudeMonitor.swift`에서:
- `StatsCacheReader` — 1차 소스(`stats-cache.json`) 경로·렌더 매핑
- `PRICING` — 폴백(JSONL) 경로의 모델별 추정 단가
- `Timer` 간격 — 기본 30초, 원하는 값으로 변경
- `FiveHourBlock.active(from:now:)` — 폴백 경로의 윈도우 계산 방식
- `BLOCK_TOKEN_BUDGET`/`BLOCK_COST_BUDGET`/`WARN_RATIO`/`CRIT_RATIO` — 사용량 경고 기본값
  (위 [사용량 경고](#사용량-경고) 참고, 환경변수로도 설정 가능)

수정 후 `./build.sh`로 재빌드하면 됩니다.

## 라이선스

[Apache License 2.0](LICENSE). 특허 라이선스 명시 부여 및 상표 보호 조항(§6)을 포함합니다.
상표·귀속 관련 고지는 [NOTICE](NOTICE)를 참고하세요.
