// ClaudeMonitor.swift
// Claude Code 5시간 블록 사용량 메뉴바 모니터
// Build:   swiftc -module-cache-path /tmp/swiftcache -o ClaudeMonitor ClaudeMonitor.swift -framework Cocoa
// Run:     ./ClaudeMonitor
// Test:    ./ClaudeMonitor --test
// Requires: macOS 12+, Claude Code CLI (https://claude.ai/code)

import Cocoa
import Foundation

let APP_VERSION = "1.7"

// MARK: - Usage Warning Config (로컬 임계값 기반 — 서버 실제 %와 무관한 근사)
//
// Claude Code의 "90% 근접" 경고는 서버 응답 헤더(anthropic-ratelimit-unified-utilization)의
// 실제 사용률이라 로컬에 저장되지 않는다(헤더는 API 호출 때만 내려옴). 여기서는 사용자가 정한
// "현재 블록 한도" 대비 근사 사용률로 유사 경고를 낸다. 한도 0 = 비활성(무설정 시 경고 없음).
// 재빌드 없이 env로도 설정: CLAUDE_MONITOR_TOKEN_BUDGET / _COST_BUDGET / _WARN / _CRIT

func envInt(_ key: String, _ def: Int) -> Int {
    guard let v = ProcessInfo.processInfo.environment[key], let n = Int(v) else { return def }
    return n
}
func envDouble(_ key: String, _ def: Double) -> Double {
    guard let v = ProcessInfo.processInfo.environment[key], let n = Double(v) else { return def }
    return n
}

let BLOCK_TOKEN_BUDGET = envInt("CLAUDE_MONITOR_TOKEN_BUDGET", 0)      // 현재 블록 totalTokens 한도
let BLOCK_COST_BUDGET  = envDouble("CLAUDE_MONITOR_COST_BUDGET", 0)   // 현재 블록 비용($) 한도
let WARN_RATIO = envDouble("CLAUDE_MONITOR_WARN", 0.90)               // 경고(주황) 임계
let CRIT_RATIO = envDouble("CLAUDE_MONITOR_CRIT", 1.00)               // 위험(빨강) 임계

enum WarnLevel { case none, warn, crit }
struct UsageWarning { let ratio: Double; let level: WarnLevel }

// 한도를 인자로 받는 순수 함수(테스트 용이). 설정된 한도가 없으면 nil.
// 토큰·비용 한도 중 더 임박한(높은) 비율을 사용률로 채택.
func computeUsageWarning(tokens: Int, cost: Double,
                         tokenBudget: Int, costBudget: Double,
                         warnAt: Double, critAt: Double) -> UsageWarning? {
    var ratio = 0.0
    var hasBudget = false
    if tokenBudget > 0 { ratio = max(ratio, Double(tokens) / Double(tokenBudget)); hasBudget = true }
    if costBudget > 0  { ratio = max(ratio, cost / costBudget); hasBudget = true }
    guard hasBudget else { return nil }
    let level: WarnLevel = ratio >= critAt ? .crit : (ratio >= warnAt ? .warn : .none)
    return UsageWarning(ratio: ratio, level: level)
}

// 현재 전역 설정값을 주입하는 래퍼.
func usageWarning(tokens: Int, cost: Double) -> UsageWarning? {
    computeUsageWarning(tokens: tokens, cost: cost,
                        tokenBudget: BLOCK_TOKEN_BUDGET, costBudget: BLOCK_COST_BUDGET,
                        warnAt: WARN_RATIO, critAt: CRIT_RATIO)
}

// MARK: - ISO8601 Parsing (공유 — JSONL 타임스탬프·stats-cache.json 파싱 양쪽에서 사용)

let iso8601FullFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
let iso8601BasicFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()
func parseISO8601(_ s: String) -> Date? {
    iso8601FullFormatter.date(from: s) ?? iso8601BasicFormatter.date(from: s)
}
func parseISO8601(_ s: String?) -> Date? {
    guard let s = s else { return nil }
    return parseISO8601(s)
}

// MARK: - Localization (macOS 시스템 언어 설정에 따른 영어/한국어 UI 전환)
//
// 이 프로젝트는 .app 번들이 없는 bare 실행 파일이라(swiftc 단일 파일 컴파일, Xcode 프로젝트 없음)
// NSLocalizedString + Localizable.strings + .lproj 같은 표준 지역화는 번들 리소스 구조를 전제로
// 하므로 그대로 쓸 수 없다. 대신 각 문자열이 쓰이는 자리에서 바로 한국어/영어를 나란히 넘기는
// 인라인 헬퍼(t(ko:en:))를 쓴다 — 이 파일의 기존 스타일(추상화 없이 각 지점에서 직접 처리)과 결이
// 맞고 리소스 파일·키 관리가 필요 없다.

enum ResolvedLanguage { case korean, english }

enum LanguagePreference: String, CaseIterable {
    case system, korean, english

    var label: String {
        switch self {
        case .system:  return t("시스템 설정 따름 (기본)", "Follow System (Default)")
        case .korean:  return "한국어"
        case .english: return "English"
        }
    }
}

// 순수 함수: 로케일 코드를 인자로 받아 테스트 용이하게 한다. 한국어가 아닌 모든 로케일은
// 영어로 폴백(2개 언어만 지원하는 현실적 기본값).
func resolveLanguage(preference: LanguagePreference, systemLanguageCode: String?) -> ResolvedLanguage {
    switch preference {
    case .korean:  return .korean
    case .english: return .english
    case .system:  return (systemLanguageCode?.hasPrefix("ko") ?? false) ? .korean : .english
    }
}

extension TitleSettings {
    private static let languageKey = "appLanguage"
    static func languagePreference(defaults: UserDefaults = .standard) -> LanguagePreference {
        guard let raw = defaults.string(forKey: languageKey), let p = LanguagePreference(rawValue: raw) else { return .system }
        return p
    }
    static func setLanguagePreference(_ p: LanguagePreference, defaults: UserDefaults = .standard) {
        defaults.set(p.rawValue, forKey: languageKey)
    }
}

// Locale.preferredLanguages는 macOS 시스템 언어 설정(제어판 > 일반 > 언어 및 지역)을 그대로
// 반영하는 순서 있는 배열이며 캐시하지 않고 매번 새로 읽는다 — 앱 실행 중 시스템 언어가 바뀌어도
// 다음 refresh()/설정 변경 시 자동 반영된다.
func currentLanguage(defaults: UserDefaults = .standard) -> ResolvedLanguage {
    resolveLanguage(preference: TitleSettings.languagePreference(defaults: defaults),
                    systemLanguageCode: Locale.preferredLanguages.first)
}

// 모든 사용자 노출 문자열이 거치는 지점.
func t(_ ko: String, _ en: String, defaults: UserDefaults = .standard) -> String {
    currentLanguage(defaults: defaults) == .korean ? ko : en
}

// MARK: - Title Field Customization (메뉴바 표시 항목 선택 — UserDefaults 영속화)

enum TitleField: String, CaseIterable {
    case outputTokens, totalTokens, cost, remainingTime, model, todayTokens, todayCost, cumulativeTokens

    var label: String {
        switch self {
        case .outputTokens:     return t("블록 출력 토큰", "Block Output Tokens")
        case .totalTokens:      return t("블록 토큰", "Block Tokens")
        case .cost:             return t("블록 비용", "Block Cost")
        case .remainingTime:    return t("남은 시간", "Time Remaining")
        case .model:            return t("모델명", "Model")
        case .todayTokens:      return t("오늘 토큰", "Today's Tokens")
        case .todayCost:        return t("오늘 비용", "Today's Cost")
        case .cumulativeTokens: return t("누적 토큰", "Cumulative Tokens")
        }
    }

    var defaultsKey: String { "titleShow_\(rawValue)" }
}

enum TitleSettings {
    private static let defaultEnabled: Set<TitleField> = [.model, .totalTokens, .cost, .remainingTime]

    static func isEnabled(_ field: TitleField, defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: field.defaultsKey) != nil else { return defaultEnabled.contains(field) }
        return defaults.bool(forKey: field.defaultsKey)
    }

    static func enabledFields(defaults: UserDefaults = .standard) -> [TitleField] {
        TitleField.allCases.filter { isEnabled($0, defaults: defaults) }
    }

    // 마지막 남은 1개는 해제 불가
    static func toggle(_ field: TitleField, defaults: UserDefaults = .standard) {
        let turningOff = isEnabled(field, defaults: defaults)
        if turningOff && enabledFields(defaults: defaults).count <= 1 { return }
        defaults.set(!turningOff, forKey: field.defaultsKey)
    }
}

enum TitleFieldColor: String, CaseIterable {
    case defaultColor = "default", red, orange, yellow, green, blue, purple, gray

    var swatch: String {  // 순환 버튼에 표시할 스와치
        switch self {
        case .defaultColor: return "⚪"
        case .red:    return "🔴"
        case .orange: return "🟠"
        case .yellow: return "🟡"
        case .green:  return "🟢"
        case .blue:   return "🔵"
        case .purple: return "🟣"
        case .gray:   return "⚫"
        }
    }

    // nil이면 렌더링 시 NSColor.labelColor(다크/라이트 자동) 사용
    var nsColor: NSColor? {
        switch self {
        case .defaultColor: return nil
        case .red:    return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green:  return .systemGreen
        case .blue:   return .systemBlue
        case .purple: return .systemPurple
        case .gray:   return .systemGray
        }
    }

    var next: TitleFieldColor {
        let all = TitleFieldColor.allCases
        let idx = all.firstIndex(of: self)!
        return all[(idx + 1) % all.count]
    }
}

extension TitleSettings {
    private static func colorKey(_ field: TitleField) -> String { "titleColor_\(field.rawValue)" }

    static func color(for field: TitleField, defaults: UserDefaults = .standard) -> TitleFieldColor {
        guard let raw = defaults.string(forKey: colorKey(field)), let c = TitleFieldColor(rawValue: raw) else { return .defaultColor }
        return c
    }

    static func setColor(_ color: TitleFieldColor, for field: TitleField, defaults: UserDefaults = .standard) {
        defaults.set(color.rawValue, forKey: colorKey(field))
    }

    static func cycleColor(for field: TitleField, defaults: UserDefaults = .standard) {
        setColor(color(for: field, defaults: defaults).next, for: field, defaults: defaults)
    }
}

enum TitleMoveDirection { case up, down }

extension TitleSettings {
    private static let orderKey = "titleFieldsOrder"
    // 신규 필드를 TitleField에 추가할 때는 여기에도 반드시 추가해야 한다 — 이 배열은
    // TitleField.allCases가 아니라 이 하드코딩된 목록 기준으로 "저장된 순서 + 누락분 자동 보강"을
    // 하므로(바로 아래 order()), 여기 빠지면 그 필드는 설정 서브메뉴에도 아예 나타나지 않는다.
    private static let defaultOrder: [TitleField] = [.model, .totalTokens, .cost, .remainingTime, .outputTokens,
                                                       .todayTokens, .todayCost, .cumulativeTokens]

    // 저장된 순서 + 신규/누락 필드는 끝에 자동 보강 (스키마 드리프트 내성 — StatsBlock 옵셔널 필드와 동일한 사고방식)
    static func order(defaults: UserDefaults = .standard) -> [TitleField] {
        guard let raw = defaults.array(forKey: orderKey) as? [String] else { return defaultOrder }
        let known = raw.compactMap(TitleField.init(rawValue:))
        let missing = defaultOrder.filter { !known.contains($0) }
        return known + missing
    }

    static func enabledFieldsInOrder(defaults: UserDefaults = .standard) -> [TitleField] {
        order(defaults: defaults).filter { isEnabled($0, defaults: defaults) }
    }

    // 경계(맨 위/맨 아래)에서는 조용히 무시
    static func move(_ field: TitleField, direction: TitleMoveDirection, defaults: UserDefaults = .standard) {
        var current = order(defaults: defaults)
        guard let idx = current.firstIndex(of: field) else { return }
        let newIdx = direction == .up ? idx - 1 : idx + 1
        guard current.indices.contains(newIdx) else { return }
        current.swapAt(idx, newIdx)
        defaults.set(current.map(\.rawValue), forKey: orderKey)
    }
}

enum TitleSeparator: String, CaseIterable {
    case space = " ", dot = " · ", pipe = " | ", none = ""
    var label: String {
        switch self {
        case .space: return t("공백", "Space")
        case .dot:   return t("가운데점 (·)", "Middle Dot (·)")
        case .pipe:  return t("세로막대 (|)", "Vertical Bar (|)")
        case .none:  return t("없음", "None")
        }
    }
}

extension TitleSettings {
    private static let separatorKey = "titleSeparator"
    static func separator(defaults: UserDefaults = .standard) -> TitleSeparator {
        guard let raw = defaults.string(forKey: separatorKey), let s = TitleSeparator(rawValue: raw) else { return .dot }
        return s
    }
    static func setSeparator(_ sep: TitleSeparator, defaults: UserDefaults = .standard) {
        defaults.set(sep.rawValue, forKey: separatorKey)
    }
}

enum TitleIcon: String, CaseIterable {
    case keyboard = "⌨", robot = "🤖", brain = "🧠", chat = "💬", bolt = "⚡", chart = "📊", diamond = "🔶", none = ""
    var label: String {
        switch self {
        case .keyboard: return t("⌨️ 키보드 (기본)", "⌨️ Keyboard (Default)")
        case .robot:    return t("🤖 로봇", "🤖 Robot")
        case .brain:    return t("🧠 두뇌", "🧠 Brain")
        case .chat:     return t("💬 말풍선", "💬 Speech Bubble")
        case .bolt:     return t("⚡ 번개", "⚡ Bolt")
        case .chart:    return t("📊 차트", "📊 Chart")
        case .diamond:  return t("🔶 다이아몬드", "🔶 Diamond")
        case .none:     return t("표시 안 함", "None")
        }
    }
}

extension TitleSettings {
    private static let iconKey = "titleIcon"
    static func icon(defaults: UserDefaults = .standard) -> TitleIcon {
        guard let raw = defaults.string(forKey: iconKey), let i = TitleIcon(rawValue: raw) else { return .keyboard }
        return i
    }
    static func setIcon(_ icon: TitleIcon, defaults: UserDefaults = .standard) {
        defaults.set(icon.rawValue, forKey: iconKey)
    }
}

enum RefreshInterval: TimeInterval, CaseIterable {
    case sec10 = 10, sec30 = 30, min1 = 60, min5 = 300
    var label: String {
        switch self {
        case .sec10: return t("10초", "10 sec")
        case .sec30: return t("30초", "30 sec")
        case .min1:  return t("1분", "1 min")
        case .min5:  return t("5분", "5 min")
        }
    }
}

enum RefreshSettings {
    private static let intervalKey = "refreshIntervalSeconds"
    static func interval(defaults: UserDefaults = .standard) -> RefreshInterval {
        RefreshInterval(rawValue: defaults.double(forKey: intervalKey)) ?? .sec30
    }
    static func setInterval(_ interval: RefreshInterval, defaults: UserDefaults = .standard) {
        defaults.set(interval.rawValue, forKey: intervalKey)
    }
}

// MARK: - Fun Mode (재미 모드 — 무드 아이콘 / 연속 사용 기록 / 마일스톤 축하, 3개 독립 토글)
//
// 세 기능은 서로 무관하므로(스트릭 기록은 보고 싶지만 타이틀을 가로채는 축하는 원치 않는 식) 하나의
// on/off 토글로 묶지 않고 기능별 독립 Bool 플래그로 관리한다. 전부 기본 OFF — 업그레이드한 기존
// 사용자의 화면은 변화 없어야 한다.

enum FunModeFeature: String, CaseIterable {
    case moodIcon, streakSection, celebrations

    var label: String {
        switch self {
        case .moodIcon:      return t("무드 아이콘", "Mood Icon")
        case .streakSection: return t("연속 사용 기록", "Streak Record")
        case .celebrations:  return t("마일스톤 축하", "Milestone Celebrations")
        }
    }

    var defaultsKey: String { "funMode_\(rawValue)" }
}

extension TitleSettings {
    static func isFunModeFeatureEnabled(_ feature: FunModeFeature, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: feature.defaultsKey)
    }
    static func setFunModeFeatureEnabled(_ feature: FunModeFeature, _ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: feature.defaultsKey)
    }
    static func toggleFunModeFeature(_ feature: FunModeFeature, defaults: UserDefaults = .standard) {
        setFunModeFeatureEnabled(feature, !isFunModeFeatureEnabled(feature, defaults: defaults), defaults: defaults)
    }
}

// 과거 FunMode(off/on) 단일 토글에서 "on"으로 켜 두었던 사용자는, 새 3-플래그 체계에서도 이전과
// 동일한 경험(무드 아이콘 + 기록 + 축하 전부 표시)을 유지하도록 1회에 한해 세 플래그를 모두 켠다.
// migrateLegacyDefaultsIfNeeded()와 동일한 "완료 워터마크 1개 키" 패턴.
private let legacyFunModeKey = "funMode"
private let funModeMigrationDoneKey = "funModeMigrated"

func migrateFunModeIfNeeded(defaults: UserDefaults = .standard) {
    guard !defaults.bool(forKey: funModeMigrationDoneKey) else { return }
    defer { defaults.set(true, forKey: funModeMigrationDoneKey) }
    guard defaults.string(forKey: legacyFunModeKey) == "on" else { return }
    for feature in FunModeFeature.allCases {
        TitleSettings.setFunModeFeatureEnabled(feature, true, defaults: defaults)
    }
}

// MARK: - Legacy Defaults Migration (ClaudeMonitor → cc-menutor 리브랜딩)
//
// 번들 ID가 없는 bare 실행 파일은 UserDefaults.standard가 실행 파일명 기준 도메인에 저장된다.
// 바이너리명이 ClaudeMonitor → cc-menutor로 바뀌면서 도메인도 함께 바뀌므로, 새 도메인이 비어
// 있을 때 1회에 한해 구 도메인(~/Library/Preferences/ClaudeMonitor.plist)에서 값을 복사해
// 기존 사용자의 커스터마이징이 리브랜딩으로 초기화된 것처럼 보이지 않게 한다.
private let legacyDefaultsDomain = "ClaudeMonitor"
private let legacyMigrationDoneKey = "legacyDefaultsMigrated"

func migrateLegacyDefaultsIfNeeded(defaults: UserDefaults = .standard,
                                    legacyDefaults: UserDefaults? = UserDefaults(suiteName: legacyDefaultsDomain)) {
    guard !defaults.bool(forKey: legacyMigrationDoneKey) else { return }
    defer { defaults.set(true, forKey: legacyMigrationDoneKey) }
    guard let legacy = legacyDefaults else { return }

    let keys = TitleField.allCases.map(\.defaultsKey)
        + TitleField.allCases.map { "titleColor_\($0.rawValue)" }
        + ["titleFieldsOrder", "titleSeparator", "titleIcon", "refreshIntervalSeconds"]
    for key in keys {
        guard defaults.object(forKey: key) == nil, let value = legacy.object(forKey: key) else { continue }
        defaults.set(value, forKey: key)
    }
}

// MARK: - Model Pricing (USD per million tokens)

struct ModelPricing {
    let input: Double
    let output: Double
    let cacheRead: Double
    let cacheWrite: Double
}

let PRICING: [(pattern: String, pricing: ModelPricing)] = [
    ("opus-4",    ModelPricing(input: 15.0,  output: 75.0,  cacheRead: 1.5,   cacheWrite: 18.75)),
    ("opus-3",    ModelPricing(input: 15.0,  output: 75.0,  cacheRead: 1.5,   cacheWrite: 18.75)),
    ("sonnet-4",  ModelPricing(input: 3.0,   output: 15.0,  cacheRead: 0.30,  cacheWrite: 3.75)),
    ("sonnet-3-7",ModelPricing(input: 3.0,   output: 15.0,  cacheRead: 0.30,  cacheWrite: 3.75)),
    ("sonnet-3-5",ModelPricing(input: 3.0,   output: 15.0,  cacheRead: 0.30,  cacheWrite: 3.75)),
    ("sonnet",    ModelPricing(input: 3.0,   output: 15.0,  cacheRead: 0.30,  cacheWrite: 3.75)),
    ("haiku-3-5", ModelPricing(input: 0.80,  output: 4.0,   cacheRead: 0.08,  cacheWrite: 1.0)),
    ("haiku",     ModelPricing(input: 0.25,  output: 1.25,  cacheRead: 0.03,  cacheWrite: 0.30)),
]

let DEFAULT_PRICING = ModelPricing(input: 3.0, output: 15.0, cacheRead: 0.30, cacheWrite: 3.75)

// Family-level fallback단가 (정밀 패턴 미매칭 시 Sonnet 일괄 폴백 대신 family 기준 적용)
let FAMILY_PRICING: [String: ModelPricing] = [
    "opus":   ModelPricing(input: 15.0, output: 75.0, cacheRead: 1.5,  cacheWrite: 18.75),
    "sonnet": ModelPricing(input: 3.0,  output: 15.0, cacheRead: 0.30, cacheWrite: 3.75),
    "haiku":  ModelPricing(input: 0.80, output: 4.0,  cacheRead: 0.08, cacheWrite: 1.0),
]

// 원본 모델 문자열의 대괄호 접미사(예: [1m])와 날짜 접미사(6자리 이상 연속 숫자)를 제거한
// 정규화 문자열. getPricing의 정밀 패턴 매칭과 parseModel의 family/버전 매칭이 모두 이 함수를
// 거친 동일한 기준으로 판단하게 해, 두 분류 로직이 서로 다른 정규화 기준으로 드리프트하지 않게 한다.
private func sanitizedModelString(_ model: String) -> String {
    var s = model.lowercased()
    s = s.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
    s = s.replacingOccurrences(of: "[0-9]{6,}", with: "", options: .regularExpression)
    return s
}

// 정밀 패턴이 매칭되면 matched=true, family/DEFAULT 폴백이면 matched=false.
func getPricing(for model: String) -> (pricing: ModelPricing, matched: Bool) {
    let s = sanitizedModelString(model)
    for (pattern, pricing) in PRICING {
        if s.contains(pattern) { return (pricing, true) }
    }
    let fam = parseModel(model).family
    if let fp = FAMILY_PRICING[fam] { return (fp, false) }
    return (DEFAULT_PRICING, false)
}

// MARK: - Model Name Parsing (버전 인식)

// "claude-opus-4-1-20250805" → ("opus", "Opus 4.1")
// "claude-3-5-sonnet-20241022" → ("sonnet", "Sonnet 3.5")
// "claude-opus-4-8[1m]" → ("opus", "Opus 4.8")
// 미상 family는 ("", 축약명) 반환.
func parseModel(_ model: String) -> (family: String, display: String) {
    let s = sanitizedModelString(model)

    let families = ["opus", "sonnet", "haiku"]
    guard let fam = families.first(where: { s.contains($0) }) else {
        let short = model.components(separatedBy: "-").prefix(3).joined(separator: "-")
        return ("", short)
    }
    let cap = fam.prefix(1).uppercased() + fam.dropFirst()

    // 버전이 family 뒤에 오는 신형 표기: opus-4-1
    if let g = regexGroups(s, "\(fam)-(\\d{1,2})(?:-(\\d{1,2}))?"), !(g.first ?? "").isEmpty {
        return (fam, "\(cap) \(versionString(g))")
    }
    // 버전이 family 앞에 오는 구형 표기: 3-5-sonnet
    if let g = regexGroups(s, "(\\d{1,2})(?:-(\\d{1,2}))?-\(fam)"), !(g.first ?? "").isEmpty {
        return (fam, "\(cap) \(versionString(g))")
    }
    return (fam, cap)
}

func shortModelName(_ model: String) -> String {
    parseModel(model).display
}

private func regexGroups(_ string: String, _ pattern: String) -> [String]? {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(string.startIndex..., in: string)
    guard let m = re.firstMatch(in: string, range: range) else { return nil }
    var groups: [String] = []
    for i in 1..<m.numberOfRanges {
        if let r = Range(m.range(at: i), in: string) {
            groups.append(String(string[r]))
        } else {
            groups.append("")
        }
    }
    return groups
}

private func versionString(_ groups: [String]) -> String {
    let major = groups.first ?? ""
    let minor = groups.count > 1 ? groups[1] : ""
    return minor.isEmpty ? major : "\(major).\(minor)"
}

// MARK: - Usage Entry

struct UsageEntry {
    let timestamp: Date
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let sessionId: String  // JSONL file name as session identifier
    let uuid: String       // 전역 중복 제거용

    var cost: Double {
        let p = getPricing(for: model).pricing
        let m = 1_000_000.0
        return Double(inputTokens) / m * p.input
             + Double(outputTokens) / m * p.output
             + Double(cacheReadTokens) / m * p.cacheRead
             + Double(cacheWriteTokens) / m * p.cacheWrite
    }

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens
    }
}

// MARK: - Data Reader (증분 파싱)

class UsageDataReader {
    let homeDir: URL
    var cachedEntries: [UsageEntry] = []

    // 파일 경로별 증분 캐시 상태
    struct FileCacheState {
        var size: UInt64       // 마지막으로 읽은 시점의 파일 크기
        var offset: UInt64     // 마지막 완전한 개행까지의 바이트 오프셋
        var entries: [UsageEntry]
    }
    private var fileCache: [String: FileCacheState] = [:]

    // 이번 readAll() 호출에서 파일이 하나라도 바뀌었는지 — false면 cachedEntries가 직전 호출과
    // 완전히 동일하다는 뜻이므로, 호출부(refresh())가 cachedAll 기반 전체 재계산(스트릭/마일스톤)을
    // 스킵할 근거로 쓴다.
    private(set) var lastReadChanged: Bool = true

    init(homeDir: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDir = homeDir
    }

    var projectsDir: URL { homeDir.appendingPathComponent(".claude/projects") }

    // 변경된 파일의 신규 줄만 읽어 누적. 메인스레드 외(백그라운드 큐)에서 호출됨.
    func readAll() -> [UsageEntry] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: projectsDir.path) else {
            fileCache.removeAll()
            cachedEntries = []
            lastReadChanged = true
            return []
        }

        guard let enumerator = fm.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            // enumerator(at:)가 nil을 반환하는 경우 이 호출은 아무 것도 관찰하지 못한 것이지 "변경
            // 없음을 확인함"이 아니므로, 직전 호출의 lastReadChanged를 그대로 흘려보내지 않게
            // 명시적으로 되돌린다.
            lastReadChanged = false
            return cachedEntries
        }

        var present = Set<String>()
        var didChange = false

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            let path = fileURL.path
            present.insert(path)

            let size = UInt64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)

            // 크기 동일 → 변경 없음, 캐시 재사용 (파일 미오픈)
            if let cached = fileCache[path], cached.size == size { continue }

            didChange = true
            let sessionId = fileURL.deletingPathExtension().lastPathComponent

            if let cached = fileCache[path], size > cached.size {
                // 증분: 이전 오프셋부터 신규 줄만 파싱
                let (newEntries, newOffset) = entries(in: fileURL, fromOffset: cached.offset, sessionId: sessionId)
                fileCache[path] = FileCacheState(size: size, offset: newOffset, entries: cached.entries + newEntries)
            } else {
                // 신규 파일 또는 트렁케이트/로테이션 → 전체 재읽기
                let (all, newOffset) = entries(in: fileURL, fromOffset: 0, sessionId: sessionId)
                fileCache[path] = FileCacheState(size: size, offset: newOffset, entries: all)
            }
        }

        // 사라진 파일 캐시 제거
        for key in Array(fileCache.keys) where !present.contains(key) {
            fileCache.removeValue(forKey: key)
            didChange = true
        }

        lastReadChanged = didChange
        // 변경된 파일이 하나도 없으면 이번 사이클의 전역 병합+dedupe+정렬(라이프타임 엔트리 수 N에
        // 비례하는 O(N log N))만 스킵하고 직전 병합 결과를 재사용한다 — 단, 위 FileManager.enumerator
        // 순회 + 파일별 fileSizeKey stat(파일 수 F에 비례하는 O(F))는 이 스킵과 무관하게 매
        // readAll() 호출마다 항상 실행된다.
        guard didChange else { return cachedEntries }

        // 전역 병합 + UUID 중복 제거 (빈 uuid는 dedupe 대상 아님)
        var seen = Set<String>()
        var merged: [UsageEntry] = []
        for state in fileCache.values {
            for e in state.entries {
                if !e.uuid.isEmpty {
                    if seen.contains(e.uuid) { continue }
                    seen.insert(e.uuid)
                }
                merged.append(e)
            }
        }
        merged.sort { $0.timestamp < $1.timestamp }
        cachedEntries = merged
        return merged
    }

    // fromOffset부터 끝까지 읽되, 마지막 완전한 개행까지만 소비하고 그 오프셋을 반환.
    // 쓰는 중인 마지막 부분 줄은 다음 주기로 미룬다.
    private func entries(in url: URL, fromOffset: UInt64, sessionId: String) -> (entries: [UsageEntry], newOffset: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ([], fromOffset) }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: fromOffset) } catch { return ([], fromOffset) }

        let data = (try? handle.readToEnd()) ?? Data()
        guard !data.isEmpty, let lastNL = data.lastIndex(of: 0x0A) else {
            return ([], fromOffset)  // 완전한 줄 없음 → 대기
        }
        let consumed = data[...lastNL]                 // 개행 포함
        let text = String(decoding: consumed, as: UTF8.self)
        let newOffset = fromOffset + UInt64(consumed.count)
        return (parseLines(text, sessionId: sessionId), newOffset)
    }

    private func parseLines(_ content: String, sessionId: String) -> [UsageEntry] {
        var result: [UsageEntry] = []
        for line in content.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            guard let msgType = json["type"] as? String, msgType == "assistant" else { continue }
            guard let message = json["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let model = message["model"] as? String
            else { continue }

            // 타임스탬프 파싱 실패 시 줄 자체를 건너뜀 (집계 오염 방지)
            guard let timestamp = parseTimestamp(json["timestamp"]) else { continue }

            let entry = UsageEntry(
                timestamp: timestamp,
                model: model,
                inputTokens:      usage["input_tokens"] as? Int ?? 0,
                outputTokens:     usage["output_tokens"] as? Int ?? 0,
                cacheReadTokens:  usage["cache_read_input_tokens"] as? Int ?? 0,
                cacheWriteTokens: usage["cache_creation_input_tokens"] as? Int ?? 0,
                sessionId: sessionId,
                uuid: json["uuid"] as? String ?? ""
            )
            result.append(entry)
        }
        return result
    }

    private func parseTimestamp(_ raw: Any?) -> Date? {
        if let s = raw as? String {
            return parseISO8601(s)
        }
        if let n = raw as? TimeInterval {
            // > 1e10 이면 밀리초로 간주
            return Date(timeIntervalSince1970: n > 1e10 ? n / 1000.0 : n)
        }
        return nil
    }
}

// MARK: - 5-Hour Block Calculator (세션 기준)

struct FiveHourBlock {
    let start: Date
    let end: Date

    var remaining: TimeInterval { max(0, end.timeIntervalSinceNow) }
    var elapsed: TimeInterval { max(0, Date().timeIntervalSince(start)) }
    var progress: Double { min(1.0, elapsed / (5 * 3600)) }
    var isActive: Bool { Date() < end }

    // entries(시간 오름차순 정렬 가정)로 블록을 재구성하고, now가 포함된 활성 블록을 반환.
    // 활성 블록이 없으면(최근 5시간 내 활동 없음) nil.
    static func active(from entries: [UsageEntry], now: Date = Date()) -> FiveHourBlock? {
        let fiveHours: TimeInterval = 5 * 3600
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!

        var start: Date? = nil
        var end = Date(timeIntervalSince1970: 0)
        var lastTs = Date(timeIntervalSince1970: 0)

        for e in entries {
            let ts = e.timestamp
            // 같은 블록 유지 조건: 현재 블록 끝 이전 && 직전 활동과의 공백 < 5시간
            let continues = start != nil && ts < end && ts.timeIntervalSince(lastTs) < fiveHours
            if !continues {
                let s = floorToHourUTC(ts, cal)
                start = s
                end = s.addingTimeInterval(fiveHours)
            }
            lastTs = ts
        }

        guard let s = start else { return nil }
        let block = FiveHourBlock(start: s, end: end)
        return now < block.end ? block : nil
    }

    private static func floorToHourUTC(_ date: Date, _ cal: Calendar) -> Date {
        let comps = cal.dateComponents([.year, .month, .day, .hour], from: date)
        return cal.date(from: comps)!
    }
}

// MARK: - Stats Summary

struct UsageStats {
    let entries: [UsageEntry]

    var totalTokens: Int      { entries.reduce(0) { $0 + $1.totalTokens } }
    var inputTokens: Int      { entries.reduce(0) { $0 + $1.inputTokens } }
    var outputTokens: Int     { entries.reduce(0) { $0 + $1.outputTokens } }
    var cacheReadTokens: Int  { entries.reduce(0) { $0 + $1.cacheReadTokens } }
    var cacheWriteTokens: Int { entries.reduce(0) { $0 + $1.cacheWriteTokens } }
    var totalCost: Double     { entries.reduce(0.0) { $0 + $1.cost } }
    var count: Int            { entries.count }

    var modelBreakdown: [(model: String, tokens: Int, cost: Double)] {
        var map: [String: (tokens: Int, cost: Double)] = [:]
        for e in entries {
            let shortModel = shortModelName(e.model)
            let cur = map[shortModel] ?? (tokens: 0, cost: 0.0)
            map[shortModel] = (tokens: cur.tokens + e.totalTokens, cost: cur.cost + e.cost)
        }
        return map.map { (model: $0.key, tokens: $0.value.tokens, cost: $0.value.cost) }
            .sorted { $0.tokens > $1.tokens }
    }

    // 정밀 단가 미매칭(추정 단가 적용) 모델 목록
    var unknownModels: [String] {
        var set = Set<String>()
        for e in entries where !getPricing(for: e.model).matched { set.insert(e.model) }
        return Array(set).sorted()
    }
}

// 블록 내 엔트리들 중 "토큰 수(총합) 기준"으로 가장 많이 쓴 모델의 원본 모델 문자열을 반환한다.
// UsageStats.modelBreakdown과 달리 shortModelName()으로 그룹핑하지 않는다 — 표시명 축약은
// 렌더링 시점(buildTitleParts)에서만 한 번 적용한다는 TitleContext.model 계약을 지키기 위함이다
// (원본을 여기서 미리 축약하면 buildTitleParts가 다시 shortModelName()을 적용해 이중 축약이 되고,
// family-버전 사이 구분자가 하이픈→공백으로 바뀌어 버전 정보가 유실될 수 있다).
// 동점 시 모델 문자열 알파벳순으로 결정론적으로 선택한다(Dictionary 순회 순서는 비결정적이므로
// 순서에 의존하면 실행마다 다른 결과가 나올 수 있다). 빈 배열이면 nil.
func mostUsedModel(in entries: [UsageEntry]) -> String? {
    var totals: [String: Int] = [:]
    for e in entries {
        totals[e.model, default: 0] += e.totalTokens
    }
    var best: (model: String, tokens: Int)?
    for (model, tokens) in totals {
        if let b = best, !(tokens > b.tokens || (tokens == b.tokens && model < b.model)) {
            continue
        }
        best = (model, tokens)
    }
    return best?.model
}

// MARK: - Formatters

func formatTokens(_ n: Int) -> String {
    switch n {
    case 0..<1_000:     return "\(n)"
    case 0..<1_000_000: return String(format: "%.1fK", Double(n) / 1_000)
    default:            return String(format: "%.2fM", Double(n) / 1_000_000)
    }
}

extension String {
    // padding(toLength:withPad:startingAt:)는 오른쪽 패딩만 지원해 왼쪽 패딩용으로 직접 추가.
    func leftPad(to width: Int, with pad: String) -> String {
        let deficit = width - count
        guard deficit > 0 else { return self }
        return String(repeating: pad, count: deficit) + self
    }
}

// 타이틀 전용 — 각 자릿수 구간(정수/K/M) 내부에서 폭을 고정해 refresh마다 값이 오를 때 생기는
// 잦은 타이틀 폭 흔들림을 줄인다. 구간 경계(999→1.0K 등, 블록 생애주기에 드물게 1회)는 정보
// 손실 없이 고정할 수 없어 그대로 둔다. 피겨 스페이스(U+2007)는 San Francisco 등 타이틀에 쓰는
// monospacedDigitSystemFont 계열에서 숫자와 동일 폭을 갖도록 설계된 문자라 패딩에 적합하다.
func formatTokensStable(_ n: Int) -> String {
    let figureSpace = "\u{2007}"
    switch n {
    case 0..<1_000:
        return String(n).leftPad(to: 3, with: figureSpace)
    case 0..<1_000_000:
        let kText = String(format: "%.1fK", Double(n) / 1_000)
        // 반올림으로 999.9K를 넘겨 "1000.0K"(7자)가 되면 구간 내 폭 고정이 깨지므로, 그 값은
        // 정보 손실 없이 M 단위로 승격해 표시한다(예: 999,950 → "1.00M").
        if kText.count > 6 {
            return String(format: "%.2fM", Double(n) / 1_000_000).leftPad(to: 7, with: figureSpace)
        }
        return kText.leftPad(to: 6, with: figureSpace)
    default:
        let mText = String(format: "%.2fM", Double(n) / 1_000_000)
        // 이 앱이 다루는 5시간 블록/일간/누적 토큰 규모를 크게 벗어나는 극단치(약 10억 근접)에서만
        // 발생 — B(10억) 단위 버킷을 새로 만들기보다 폭 고정을 지키는 쪽을 택해 상한 고정 표기한다.
        if mText.count > 7 {
            return "999.99M"
        }
        return mText.leftPad(to: 7, with: figureSpace)
    }
}

func formatCost(_ c: Double) -> String {
    if c < 0.01 { return String(format: "$%.4f", c) }
    return String(format: "$%.2f", c)
}

func formatTime(_ interval: TimeInterval) -> String {
    let h = Int(interval) / 3600
    let m = (Int(interval) % 3600) / 60
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}

func progressBar(_ ratio: Double, width: Int = 10) -> String {
    let filled = Int(ratio * Double(width))
    let empty = width - filled
    return "[" + String(repeating: "█", count: filled) + String(repeating: "░", count: empty) + "]"
}

func formatTimeShort(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.timeStyle = .short
    formatter.dateStyle = .none
    return formatter.string(from: date)
}

// MARK: - Mood Tier (재미 모드 — 5시간 블록 진행 상태 기반 무드 글리프)
//
// 컬러 프레젠테이션 이모지(🔥😅 등)는 NSAttributedString.foregroundColor가 적용되지 않아
// 색이 바뀌지 않는다. Geometric Shapes 블록의 텍스트 프레젠테이션 글리프를 사용해야
// "색상 변화"가 실제로 동작한다.

enum MoodTier: String, CaseIterable {
    case idle, calm, warm, hot, critical

    var glyph: String {
        switch self {
        case .idle:     return "○"
        case .calm:     return "◔"
        case .warm:     return "◑"
        case .hot:      return "◕"
        case .critical: return "●"
        }
    }
    var color: TitleFieldColor {
        switch self {
        case .idle:     return .gray
        case .calm:     return .green
        case .warm:     return .yellow
        case .hot:      return .orange
        case .critical: return .red
        }
    }
    var label: String {   // 드롭다운 범례용
        switch self {
        case .idle:     return t("대기", "Idle")
        case .calm:     return t("여유", "Calm")
        case .warm:     return t("몰입", "Focused")
        case .hot:      return t("가속", "Accelerating")
        case .critical: return t("한계 근접", "Near Limit")
        }
    }
}

// flame 테마 전용 — MoodTier(5단계)를 아이콘 모양 3단계(불씨/불꽃/화염)로 묶는다. idle+calm을
// 묶는 이유: 블록이 없거나 막 시작한 시점엔 "아직 불이 크지 않다"는 신호가 맞고, warm+hot을
// 묶는 이유: 대부분의 작업 시간이 여기 걸쳐 있어 형태 변화보다 색 변화(노랑→주황)로 충분히
// 구분됨. critical만 별도 화염 형태로 분리해 "한도 근접"을 형태로도 강조한다.
enum FlameStage: String, CaseIterable {
    case ember, flame, blaze   // 불씨 / 불꽃 / 화염
}

func flameStage(for tier: MoodTier) -> FlameStage {
    switch tier {
    case .idle, .calm: return .ember
    case .warm, .hot:  return .flame
    case .critical:    return .blaze
    }
}

// flame/blaze 단계 전용 흔들림(flicker) 애니메이션 튜닝 포인트.
let flameFlickerInterval: TimeInterval = 0.2   // 흔들림 재계산 주기(초당 5회, 상태바 이미지만 재대입 — 가벼움)
let flameFlickerPeriod: TimeInterval = 1.6      // 메인(느린) 숨쉬기 흔들림 한 주기(초)

// 시간 기반 흔들림 값(대략 -1...1). elapsed는 보통 Date().timeIntervalSinceReferenceDate를 그대로 넣는다.
// 느린 주성분(flameFlickerPeriod, 전체가 숨쉬듯 부풀었다 줄었다)에 더 빠르고 진폭 작은 보조
// 성분(주기 ≈ 0.31배, 끝이 날름거리듯 잔떨림)을 얹어 완전한 주기성을 깬다 — 단일 sin 하나만 쓰면
// 좌우로 똑같은 리듬으로 왔다갔다하는 "흔들의자" 같은 인상이라 실제 불꽃의 불규칙한 일렁임과는
// 거리가 멀다. phaseShift로 서로 다른 위상을 줘 blaze의 메인/곁불꽃이 따로 움직이게 한다.
func flameSway(elapsed: TimeInterval, phaseShift: Double = 0) -> CGFloat {
    let slow = sin(elapsed * 2.0 * .pi / flameFlickerPeriod + phaseShift)
    let fast = sin(elapsed * 2.0 * .pi / (flameFlickerPeriod * 0.31) + phaseShift * 1.7) * 0.4
    return CGFloat(slow + fast) / 1.4   // 두 성분 합의 최대치(1.4)로 나눠 대략 -1...1로 정규화
}

// 무드 글리프의 "모양" 테마 — 색(TitleFieldColor)은 테마와 무관하게 MoodTier.color 그대로 쓴다.
// 자유 텍스트 입력을 허용하지 않는 이유: 컬러 프레젠테이션 이모지를 넣으면 위 색상 틴팅이 조용히
// 먹히지 않기 때문에(:712 주석 참고), 색 틴팅이 검증된 텍스트 프레젠테이션 글리프로만 구성된
// 테마 중에서 고르게 한다.
enum MoodGlyphTheme: String, CaseIterable {
    case circles, bars, signature, flame

    var label: String {
        switch self {
        case .circles:   return t("○ 원형 (기본)", "○ Circles (Default)")
        case .bars:      return t("▁ 막대", "▁ Bars")
        case .signature: return t("▮ 시그니쳐 (커서 블록)", "▮ Signature (Cursor Block)")
        case .flame:     return t("🔥 불꽃 (불씨 → 화염)", "🔥 Flame (Ember → Blaze)")
        }
    }

    // signature/flame 테마는 텍스트 글리프가 아니라 statusItem.button.image로 렌더링되므로(아래
    // moodSignatureImage/moodFlameImage 참고) 이 값을 참조하는 호출부는 이미지 테마일 때 스킵한다.
    var isImageBased: Bool { self == .signature || self == .flame }

    // signature/flame은 텍스트 글리프가 아니라 이미지로 렌더링되므로 이 함수는 실제로 호출되지
    // 않는다 — circles와 동일한 값을 반환해 만에 하나 호출되더라도(예: 향후 새 호출부 추가 실수)
    // 빈 문자열 대신 안전한 폴백을 준다.
    func glyph(for tier: MoodTier) -> String {
        switch self {
        case .circles, .signature, .flame:
            return tier.glyph
        case .bars:
            switch tier {
            case .idle:     return "▁"
            case .calm:     return "▃"
            case .warm:     return "▅"
            case .hot:      return "▇"
            case .critical: return "█"
            }
        }
    }
}

// signature 테마 전용 커스텀 벡터 아이콘 — 유니코드 글리프 대신 Core Graphics로 직접 그린
// "터미널 커서 블록" 모티프(Claude Code가 CLI 도구라는 정체성과 연결). tier가 올라갈수록 블록
// 안쪽 채움이 바닥부터 차오른다.
func moodSignatureImage(tier: MoodTier) -> NSImage {
    let size = CGSize(width: 11, height: 14)
    let fillRatio: CGFloat
    switch tier {
    case .idle:     fillRatio = 0
    case .calm:     fillRatio = 0.25
    case .warm:     fillRatio = 0.5
    case .hot:      fillRatio = 0.75
    case .critical: fillRatio = 1.0
    }
    let color = tier.color.nsColor ?? .labelColor
    let image = NSImage(size: size, flipped: false) { rect in
        let outlineRect = rect.insetBy(dx: 1, dy: 1)
        let outline = NSBezierPath(roundedRect: outlineRect, xRadius: 2, yRadius: 2)
        color.withAlphaComponent(0.4).setStroke()
        outline.lineWidth = 1
        outline.stroke()
        if fillRatio > 0 {
            let fillHeight = max(0, outlineRect.height * fillRatio - 2)
            let fillRect = CGRect(x: outlineRect.minX + 1.5, y: outlineRect.minY + 1.5,
                                   width: outlineRect.width - 3, height: fillHeight)
            let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: 1, yRadius: 1)
            color.withAlphaComponent(0.85).setFill()
            fillPath.fill()
        }
        return true
    }
    image.isTemplate = false
    return image
}

// flame 테마 전용 배색 — circles/bars/signature 테마가 공유하는 MoodTier.color(회색/초록/노랑/
// 주황/빨강 "신호등" 배색)와는 별개다. 저 배색을 그대로 썼다면 calm이 초록으로 나와 "불씨"라는
// 형태와 어긋난다. 빨강은 critical 전용으로 예약해(calm/warm/hot은 노랑~주황 범위에서만 움직임)
// 낮은 진행률에서 빨강이 섞여 "한도를 다 썼다"는 오해를 주지 않게 한다. mid/inner가 nil이면(idle)
// 코어 하이라이트 없이 완전히 식은 색만 쓴다 — idle은 활성 블록이 없는 상태라 실제로 "타는 중"이
// 아니므로 불꽃 코어를 얹지 않는다. outer(빨강)→mid(주황)→inner(노랑) 3톤은 실제 불꽃의 겉→속
// 온도 변화(불꽃 이모지 🔥의 배색)를 겨냥한 것 — 기존 2톤(outer/inner)보다 한 겹 더 넣어 코어가
// "밝은 색 얼룩"이 아니라 화염 중심에서 번져 나오는 것처럼 보이게 한다.
func flameColors(for tier: MoodTier) -> (outer: NSColor, mid: NSColor?, inner: NSColor?) {
    switch tier {
    case .idle:
        return (NSColor(calibratedWhite: 0.55, alpha: 1), nil, nil)
    case .calm:
        return (NSColor(calibratedRed: 0.72, green: 0.24, blue: 0.10, alpha: 1),
                NSColor(calibratedRed: 0.88, green: 0.42, blue: 0.14, alpha: 1),
                NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.20, alpha: 1))
    case .warm:
        return (NSColor(calibratedRed: 0.95, green: 0.45, blue: 0.05, alpha: 1),
                NSColor(calibratedRed: 0.98, green: 0.62, blue: 0.12, alpha: 1),
                NSColor(calibratedRed: 1.00, green: 0.80, blue: 0.20, alpha: 1))
    case .hot:
        return (NSColor(calibratedRed: 0.92, green: 0.32, blue: 0.04, alpha: 1),
                NSColor(calibratedRed: 0.96, green: 0.58, blue: 0.14, alpha: 1),
                NSColor(calibratedRed: 1.00, green: 0.85, blue: 0.25, alpha: 1))
    case .critical:
        return (NSColor(calibratedRed: 0.88, green: 0.16, blue: 0.10, alpha: 1),
                NSColor(calibratedRed: 0.94, green: 0.50, blue: 0.16, alpha: 1),
                NSColor(calibratedRed: 1.00, green: 0.90, blue: 0.35, alpha: 1))
    }
}

// flame 테마 전용 커스텀 벡터 아이콘 — 이모지 🔥 대신 Core Graphics로 직접 그려 색 틴팅이
// 정상 동작하게 한다(파일 상단 MoodGlyphTheme 주석 참고). FlameStage(3단계: 불씨/불꽃/화염)에
// 따라 실루엣 자체가 커지고 복잡해진다 — 불씨는 화염 모양이 아니라 둥근 점, 불꽃은 표준 화염
// 한 덩이, 화염은 메인 화염 옆에 곁불꽃이 하나 더 붙는다. flameColors(for:)의 outer/mid/inner 3톤을
// 겹쳐 칠해 실제 불꽃처럼 겉은 진하고 속은 밝은 느낌을 낸다 — mid는 가로 72%·세로 85%, 코어는
// 가로 55%·세로 70%로 줄이고 바닥은 그대로 맞춰(가운데 정렬 아님) 밑에서부터 차오르는 것처럼
// 보이게 한다. elapsed(기본 0)를 넘기면 flame/blaze 단계 실루엣이 flameSway()로 미세하게
// 일렁인다 — ember는 항상 elapsed와 무관하게 정적이다(flameBezierPath 참고).
func moodFlameImage(tier: MoodTier, elapsed: TimeInterval = 0) -> NSImage {
    let size = CGSize(width: 11, height: 14)
    let colors = flameColors(for: tier)
    let stage = flameStage(for: tier)
    let image = NSImage(size: size, flipped: false) { rect in
        colors.outer.setFill()
        flameBezierPath(stage: stage, in: rect, elapsed: elapsed).fill()
        if let mid = colors.mid {
            let midRect = CGRect(x: rect.midX - rect.width * 0.36, y: rect.minY,
                                  width: rect.width * 0.72, height: rect.height * 0.85)
            mid.setFill()
            flameBezierPath(stage: stage, in: midRect, elapsed: elapsed).fill()
        }
        if let inner = colors.inner {
            let coreRect = CGRect(x: rect.midX - rect.width * 0.275, y: rect.minY,
                                   width: rect.width * 0.55, height: rect.height * 0.70)
            inner.setFill()
            flameBezierPath(stage: stage, in: coreRect, elapsed: elapsed).fill()
        }
        return true
    }
    image.isTemplate = false
    return image
}

// 단일 화염 실루엣 — 정규화 좌표(밑변 중앙 근처가 원점)로 정의한 뒤 rect에 맞춰 스케일한다.
// lean이 클수록 끝이 오른쪽으로(음수면 왼쪽으로) 기울어 "일렁이는" 인상을 준다.
// 밑변은 평평하게(불꽃이 바닥에 "앉은" 인상), 옆선은 각각 단일 베지어 한 번으로 배(볼록)에서
// 끝까지 S자로 휘어 오르게 해 물방울과 구분되는 "일렁이는 불꽃" 실루엣을 만든다. 앵커를 늘려
// 허리/어깨 단을 추가로 넣어본 적이 있는데, 양쪽을 대칭으로 접으면 마디가 층층이 쌓인 모양이
// 되어(💩 실루엣과 흡사) 오히려 나빠졌다 — 그래서 옆선마다 앵커 하나(밑변 끝)에서 끝(tip)까지
// 곡선 1개로만 잇는다. 앵커가 적을수록 이어붙는 지점에서 생기는 꺾임(kink) 위험도 준다.
// 좌우 곡선의 제어점은 서로 대칭이 아니라 비대칭이다 — 왼쪽은 배가 낮고 빠르게 좁아지고(어깨),
// 오른쪽은 더 완만하게 길게 뻗어 tip이 중심보다 오른쪽으로 치우친다(🔥 이모지 실루엣 참고).
// 대칭 물방울보다 실제 불꽃처럼 한쪽으로 흐르는 인상을 주면서도, 옆선마다 곡선 1개라는 원칙은
// 그대로 지켜 앞 문단의 꺾임/뭉침 문제를 재도입하지 않는다. 제어점은 11x14pt 실제 크기(및
// 22x28/33x42 배율)로 렌더링해 가며 맞췄다 — 캔버스 경계에 바짝 붙이면(과거 시도) 배→끝 구간의
// 급격한 곡률이 극소 크기에서 뭉툭/각진 인상으로 보여, 제어점을 안쪽으로 당겨 완만하게 잡는다.
private func singleFlamePath(in rect: CGRect, lean: CGFloat) -> NSBezierPath {
    func pt(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
        CGPoint(x: rect.minX + u * rect.width, y: rect.minY + v * rect.height)
    }
    let path = NSBezierPath()
    path.move(to: pt(0.18, 0.0))
    path.line(to: pt(0.82, 0.0))
    path.curve(to: pt(0.62 + lean, 1.0), controlPoint1: pt(0.94, 0.46), controlPoint2: pt(0.66 + lean * 0.3, 0.88))
    path.curve(to: pt(0.18, 0.0), controlPoint1: pt(0.30 + lean * 0.3, 0.58), controlPoint2: pt(0.02, 0.26))
    path.close()
    return path
}

// elapsed(기본 0)는 flame/blaze 단계에서만 쓰인다 — ember는 무시해 항상 정적으로 유지한다
// (모니터링 활성 블록이 없는 idle/calm 상태에 흔들림을 주면 "계산이 진행 중"이라는 정보와
// 어긋나므로 의도적으로 제외).
private func flameBezierPath(stage: FlameStage, in rect: CGRect, elapsed: TimeInterval = 0) -> NSBezierPath {
    switch stage {
    case .ember:
        // 화염 실루엣이 아니라 바닥에 깔린 작고 둥근 불씨 — 높이 canvas의 ~42%
        let height = rect.height * 0.42
        let width = rect.width * 0.62
        let emberRect = CGRect(x: rect.midX - width / 2, y: rect.minY, width: width, height: height)
        return NSBezierPath(ovalIn: emberRect)
    case .flame:
        // 표준 물방울형 화염 실루엣 — 높이 ~78%, 살짝 기울어진 단일 불꽃. flameSway로 높이(±7%)와
        // lean(±16%)을 흔들어 "타오르는" 느낌을 낸다 — lean은 singleFlamePath 정의상 끝부분(v≈1)
        // 제어점만 크게 움직이므로 뿌리는 고정된 채 끝만 날름거리는 모양이 자연히 나온다.
        let sway = flameSway(elapsed: elapsed)
        let height = rect.height * (0.78 + sway * 0.07)
        let flameRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height)
        return singleFlamePath(in: flameRect, lean: 0.03 + sway * 0.16)
    case .blaze:
        // 메인 화염(높이 ~98%) + 옆에 작은 곁불꽃 — 가장 크고 밝은 단계. 메인/곁불꽃에 서로 다른
        // 위상의 sway를 줘 두 불꽃이 따로 움직이게 하고, x에도 미세한 흔들림을 더해 함께 춤추듯 보이게 한다.
        let mainSway = flameSway(elapsed: elapsed)
        let mainHeight = rect.height * (0.98 + mainSway * 0.07)
        let mainRect = CGRect(x: rect.minX + rect.width * 0.12 + mainSway * rect.width * 0.02, y: rect.minY,
                               width: rect.width * 0.75, height: mainHeight)
        let main = singleFlamePath(in: mainRect, lean: 0.03 + mainSway * 0.16)
        let sideSway = flameSway(elapsed: elapsed, phaseShift: 2.4)
        let sideHeight = rect.height * (0.55 + sideSway * 0.07)
        let sideRect = CGRect(x: rect.minX - rect.width * 0.05 + sideSway * rect.width * 0.02, y: rect.minY,
                               width: rect.width * 0.5, height: sideHeight)
        main.append(singleFlamePath(in: sideRect, lean: -0.06 + sideSway * 0.16))
        return main
    }
}

// statusItem.button.image에 대입할 이미지 — signature/flame 테마가 선택되어 있고 아이콘이 표시
// 상태(TitleIcon != .none)이며 무드 타이어가 있을 때만 non-nil. 그 외에는 nil을 반환해 호출부가
// "이전 테마의 잔류 이미지 지우기"에도 그대로 쓸 수 있게 한다(테마를 circles/bars로 되돌렸을 때
// 이전 프레임 이미지가 남아있지 않도록).
func moodImageToApply(tier: MoodTier?) -> NSImage? {
    let theme = TitleSettings.moodGlyphTheme()
    guard TitleSettings.icon() != .none,
          theme.isImageBased,
          let tier = tier else { return nil }
    // flame 테마는 refresh 트리거 시점에도 refreshFlameFlicker()가 매 0.2초마다 그리는 것과 동일한
    // "지금 시각" 흔들림 프레임을 써야 한다 — elapsed를 0으로 고정하면 매 refresh마다 아이콘이 rest
    // 포즈로 스냅됐다가 최대 0.2초 뒤 흔들림 타이머가 되돌리는 깜빡임이 생긴다.
    return theme == .signature ? moodSignatureImage(tier: tier)
                                : moodFlameImage(tier: tier, elapsed: Date().timeIntervalSinceReferenceDate)
}

extension TitleSettings {
    private static let moodGlyphThemeKey = "moodGlyphTheme"
    static func moodGlyphTheme(defaults: UserDefaults = .standard) -> MoodGlyphTheme {
        guard let raw = defaults.string(forKey: moodGlyphThemeKey), let t = MoodGlyphTheme(rawValue: raw) else { return .circles }
        return t
    }
    static func setMoodGlyphTheme(_ theme: MoodGlyphTheme, defaults: UserDefaults = .standard) {
        defaults.set(theme.rawValue, forKey: moodGlyphThemeKey)
    }
}

// 순수 함수: 활성 블록 여부 + 경과 비율(예산 미설정 시) + usageWarning 비율(예산 설정 시, 우선)로 tier 산출.
// 임계값은 warnAt(기본 WARN_RATIO=0.90)에서 파생되어, CLAUDE_MONITOR_WARN으로 임계값을 바꿔도
// 무드 색(주황/빨강)과 실제 경고 배너가 어긋나지 않는다.
func computeMood(hasActiveBlock: Bool, elapsedRatio: Double, warning: UsageWarning?,
                  warnAt: Double = WARN_RATIO) -> MoodTier {
    guard hasActiveBlock else { return .idle }
    let ratio = warning?.ratio ?? elapsedRatio
    // warnAt이 기본값(0.90)이면 scale은 정확히 1.0(IEEE754 x/x==1.0)이라 기존 0.34/0.67 경계와
    // 완전히 동일하게 나옴. CLAUDE_MONITOR_WARN로 warnAt이 바뀌면 hot/critical 경계뿐 아니라
    // calm/warm/hot 경계도 비례해서 따라가 무드 색이 실제 경고 임계값과 어긋나지 않게 한다.
    let scale = warnAt / 0.90
    switch ratio {
    case ..<(0.34 * scale): return .calm
    case ..<(0.67 * scale): return .warm
    case ..<warnAt:         return .hot
    default:                return .critical
    }
}

// QA 전용: 수동 검증 시 CLAUDE_MONITOR_MOOD_TEST_TIER=hot 처럼 지정해 tier를 강제로 고정한다.
// 실제 사용자 경험에는 영향 없음(값이 없으면 nil이라 계산 결과를 그대로 씀).
func moodTestTierOverride() -> MoodTier? {
    guard let raw = ProcessInfo.processInfo.environment["CLAUDE_MONITOR_MOOD_TEST_TIER"] else { return nil }
    return MoodTier(rawValue: raw)
}

// MARK: - Gamification (재미 모드 — 일일 사용 스트릭 + 개인 최고 기록)
//
// 재미 모드 토글과 무관하게 refresh()마다 항상 갱신한다(§3 참고) — 스트릭은 실제 사용일을
// 반영해야 하므로, 표시가 꺼져 있다고 갱신을 건너뛰면 나중에 재미 모드를 켰을 때 그 사이의
// 활동이 반영되지 않은 잘못된 공백/리셋이 발생한다. 드롭다운 노출만 재미 모드로 게이팅한다.

struct GamificationRecord: Equatable {
    var currentStreakDays: Int
    var longestStreakDays: Int
    var lastActiveDay: String   // "yyyy-MM-dd", 로컬 달력 기준
    var bestDayTokens: Int
    var bestDayCost: Double

    static let empty = GamificationRecord(currentStreakDays: 0, longestStreakDays: 0,
                                           lastActiveDay: "", bestDayTokens: 0, bestDayCost: 0)
}

enum GamificationSettings {
    private static let currentStreakKey = "gamCurrentStreakDays"
    private static let longestStreakKey = "gamLongestStreakDays"
    private static let lastActiveDayKey = "gamLastActiveDay"
    private static let bestDayTokensKey = "gamBestDayTokens"
    private static let bestDayCostKey   = "gamBestDayCost"

    static func load(defaults: UserDefaults = .standard) -> GamificationRecord {
        GamificationRecord(
            currentStreakDays: defaults.integer(forKey: currentStreakKey),
            longestStreakDays: defaults.integer(forKey: longestStreakKey),
            lastActiveDay: defaults.string(forKey: lastActiveDayKey) ?? "",
            bestDayTokens: defaults.integer(forKey: bestDayTokensKey),
            bestDayCost: defaults.double(forKey: bestDayCostKey))
    }
    static func save(_ r: GamificationRecord, defaults: UserDefaults = .standard) {
        defaults.set(r.currentStreakDays, forKey: currentStreakKey)
        defaults.set(r.longestStreakDays, forKey: longestStreakKey)
        defaults.set(r.lastActiveDay, forKey: lastActiveDayKey)
        defaults.set(r.bestDayTokens, forKey: bestDayTokensKey)
        defaults.set(r.bestDayCost, forKey: bestDayCostKey)
    }
}

func localDayString(_ date: Date, timeZone: TimeZone = .current) -> String {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = timeZone
    return f.string(from: date)
}

private func daysBetween(_ a: String, _ b: String) -> Int? {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone.current
    guard let da = f.date(from: a), let db = f.date(from: b) else { return nil }
    return Calendar.current.dateComponents([.day], from: da, to: db).day
}

// 이전 기록 + 오늘 날짜(yyyy-MM-dd, 로컬) + 오늘 누적 토큰/비용 → 새 기록.
// 오늘 활동이 0이면 상태를 그대로 반환(감소·리셋 금지 — 단절 판정은 오직 "다음 활동이 있는 날"의
// 갭 계산에서만). 같은 날 재호출(멱등)은 스트릭을 중복 증가시키지 않고 최고 기록만 ratchet-up.
func computeGamification(previous: GamificationRecord, today: String,
                          todayTokens: Int, todayCost: Double) -> GamificationRecord {
    guard todayTokens > 0 || todayCost > 0 else { return previous }

    var next = previous
    next.bestDayTokens = max(previous.bestDayTokens, todayTokens)
    next.bestDayCost = max(previous.bestDayCost, todayCost)

    if previous.lastActiveDay == today {
        return next   // 같은 날 재호출: 최고 기록만 갱신
    }
    if previous.lastActiveDay.isEmpty {
        next.currentStreakDays = 1
    } else if daysBetween(previous.lastActiveDay, today) == 1 {
        next.currentStreakDays = previous.currentStreakDays + 1
    } else {
        next.currentStreakDays = 1   // 공백 2일 이상(또는 파싱 실패/시계 역행) → 리셋
    }
    next.longestStreakDays = max(previous.longestStreakDays, next.currentStreakDays)
    next.lastActiveDay = today
    return next
}

// MARK: - Easter Eggs (재미 모드 — 평생 누적 토큰 / 연속 스트릭 마일스톤 축하)
//
// 무겁게 새로 계산하지 않는다 — 이미 매 refresh()마다 계산되는 값(전체 누적 토큰, 스트릭)에 대해
// "지금까지 알린 최고 마일스톤" 워터마크만 비교한다. 토큰 총합은 stats.cumulative(1차 캐시 경로에만
// 존재)가 아니라 UsageStats(entries: cachedAll).totalTokens로 계산한다 — Gamification과 동일하게
// 1차/폴백 경로 어느 쪽이든 항상 채워지는 cachedAll을 신뢰해야 폴백 모드에서도 추적이 끊기지 않는다.

let tokenMilestones: [Int]  = [1_000_000, 10_000_000, 100_000_000, 1_000_000_000]
let streakMilestones: [Int] = [7, 30, 100]

struct MilestoneCheckResult { let announced: Int; let justCrossed: Int? }

// 순수 함수. currentValue가 이미 넘은 가장 높은 threshold(highestReached)와 이전에 알린 값(prev)을
// 비교한다.
//  - prev == nil(최초 실행): 지금까지 넘은 마일스톤을 "알림 없이" 워터마크로만 백필한다. 그렇지
//    않으면 기존 헤비 유저가 이 기능을 처음 켰을 때 지난 마일스톤이 한꺼번에 쏟아진다
//    (computeGamification의 lastActiveDay.isEmpty 첫 실행 처리와 동일한 관용구).
//  - highestReached가 prev보다 클 때만 1회 발화. 한 사이클에 여러 단계를 건너뛰어도(prev=0 →
//    currentValue가 1M과 10M을 동시에 넘김) .max()가 가장 높은 단계 하나만 골라 한 번만 발화한다.
//  - currentValue가 감소해도(스트릭 리셋, 또는 극단적으로 JSONL이 정리되어 평생 토큰 총합이
//    줄어드는 경우) prev는 절대 낮아지지 않는다 — reached > prev가 아니면 이 함수는 항상
//    announced: prev(그대로)를 반환하므로 워터마크는 스스로 ratchet-up만 한다. "이미 달성한
//    마일스톤"이 다시 사라지지 않는(게임 업적과 동일한) 영구 기록 시맨틱이며, 별도 max() 래핑이
//    필요 없다.
func checkMilestone(currentValue: Int, thresholds: [Int], previouslyAnnounced: Int?) -> MilestoneCheckResult {
    let highestReached = thresholds.filter { $0 <= currentValue }.max()
    guard let prev = previouslyAnnounced else {
        return MilestoneCheckResult(announced: highestReached ?? 0, justCrossed: nil)
    }
    guard let reached = highestReached, reached > prev else {
        return MilestoneCheckResult(announced: prev, justCrossed: nil)
    }
    return MilestoneCheckResult(announced: reached, justCrossed: reached)
}

enum EasterEggSettings {
    private static let tokenMilestoneKey  = "eggAnnouncedTokenMilestone"
    private static let streakMilestoneKey = "eggAnnouncedStreakMilestone"

    // object(forKey:) as? Int를 쓴다(GamificationSettings의 integer(forKey:)와 의도적으로 다름) —
    // "키가 없음"(nil, 최초 실행)과 "워터마크가 정당하게 0"을 구분해야 checkMilestone()의 백필
    // 분기가 성립한다. integer(forKey:)를 썼다면 항상 0이 반환되어 최초 실행도 이미 확인된 것으로
    // 오인되고, previouslyAnnounced가 nil로 전달될 일이 없어 백필 분기 자체가 죽은 코드가 된다.
    static func announcedTokenMilestone(defaults: UserDefaults = .standard) -> Int? {
        defaults.object(forKey: tokenMilestoneKey) as? Int
    }
    static func setAnnouncedTokenMilestone(_ v: Int, defaults: UserDefaults = .standard) {
        defaults.set(v, forKey: tokenMilestoneKey)
    }
    static func announcedStreakMilestone(defaults: UserDefaults = .standard) -> Int? {
        defaults.object(forKey: streakMilestoneKey) as? Int
    }
    static func setAnnouncedStreakMilestone(_ v: Int, defaults: UserDefaults = .standard) {
        defaults.set(v, forKey: streakMilestoneKey)
    }
}

// MARK: - Title Text Rendering (경로 무관 공통 조합)

struct TitleContext {
    let outputTokens: Int
    let totalTokens: Int
    let cost: Double
    let remainingText: String?   // 이미 formatTime()된 문자열, 알 수 없으면 nil
    let model: String?           // shortModelName 적용 전 원본 모델 문자열
    let moodTier: MoodTier?      // 재미 모드 ON일 때만 non-nil — OFF면 기존 아이콘 로직과 동일 출력 보장
    let todayTokens: Int
    let todayCost: Double
    let cumulativeTokens: Int

    // moodTier 이후 추가되는 필드는 전부 기본값을 줘 기존 호출부가 그대로 컴파일되게 한다.
    init(outputTokens: Int, totalTokens: Int, cost: Double, remainingText: String?, model: String?,
         moodTier: MoodTier? = nil,
         todayTokens: Int = 0, todayCost: Double = 0, cumulativeTokens: Int = 0) {
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.cost = cost
        self.remainingText = remainingText
        self.model = model
        self.moodTier = moodTier
        self.todayTokens = todayTokens
        self.todayCost = todayCost
        self.cumulativeTokens = cumulativeTokens
    }
}

// idle/no-data 고정 문자열과 launch placeholder도 이 값을 공유해 커스터마이징과 어긋나지 않게 한다.
func titleIconPrefix() -> String {
    let icon = TitleSettings.icon().rawValue
    return icon.isEmpty ? "" : "\(icon) "
}

struct TitlePart { let text: String; let color: TitleFieldColor }

func buildTitleParts(_ ctx: TitleContext) -> [TitlePart] {
    var parts: [TitlePart] = []
    // ctx.moodTier는 재미 모드 ON일 때만 non-nil — OFF면 기존처럼 정적 TitleIcon을 그대로 사용해
    // 출력이 이전과 동일함을 보장한다. 사용자가 아이콘을 "표시 안 함"으로 두면 무드도 함께 숨긴다.
    if TitleSettings.icon() != .none {
        if let tier = ctx.moodTier {
            // signature/flame 테마는 텍스트 파트가 아니라 statusItem.button.image로 렌더링된다
            // (호출부의 moodImageToApply(tier:) 참고) — 여기서는 글리프 텍스트를 아예 만들지 않는다.
            if !TitleSettings.moodGlyphTheme().isImageBased {
                parts.append(TitlePart(text: TitleSettings.moodGlyphTheme().glyph(for: tier), color: tier.color))
            }
        } else {
            let icon = TitleSettings.icon().rawValue
            if !icon.isEmpty { parts.append(TitlePart(text: icon, color: .defaultColor)) }
        }
    }
    for field in TitleSettings.enabledFieldsInOrder() {
        switch field {
        case .outputTokens:     parts.append(TitlePart(text: formatTokensStable(ctx.outputTokens), color: TitleSettings.color(for: field)))
        case .totalTokens:      parts.append(TitlePart(text: formatTokensStable(ctx.totalTokens), color: TitleSettings.color(for: field)))
        case .cost:             parts.append(TitlePart(text: formatCost(ctx.cost), color: TitleSettings.color(for: field)))
        case .remainingTime:    if let r = ctx.remainingText { parts.append(TitlePart(text: r, color: TitleSettings.color(for: field))) }
        case .model:            if let m = ctx.model { parts.append(TitlePart(text: shortModelName(m), color: TitleSettings.color(for: field))) }
        case .todayTokens:      parts.append(TitlePart(text: formatTokensStable(ctx.todayTokens), color: TitleSettings.color(for: field)))
        case .todayCost:        parts.append(TitlePart(text: formatCost(ctx.todayCost), color: TitleSettings.color(for: field)))
        case .cumulativeTokens: parts.append(TitlePart(text: formatTokensStable(ctx.cumulativeTokens), color: TitleSettings.color(for: field)))
        }
    }
    return parts
}

func buildTitleText(_ ctx: TitleContext) -> String {
    buildTitleParts(ctx).map(\.text).joined(separator: TitleSettings.separator().rawValue)
}

// MARK: - Stats Cache (Claude Code's own aggregate, ~/.claude/stats-cache.json)
//
// Claude Code CLI가 직접 유지하는 권위 있는 사용량 집계. 이 앱이 손으로 재구현하던
// 5시간 블록·비용을 CLI가 이미 계산해 두므로 1차 소스로 사용한다.
// 스키마는 비공식이라 버전에 따라 바뀔 수 있음 → StatsBlock은 strict,
// 부차 필드(PeriodStats/ModelBreakdown)는 옵셔널로 느슨하게 두어 부분 드리프트에 견딘다.


struct TokenCounts: Codable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationInputTokens: Int
    let cacheReadInputTokens: Int
}
struct BurnRate: Codable {
    let tokensPerMinute: Double?
    let costPerHour: Double?
}
struct Projection: Codable {
    let totalTokens: Int?
    let totalCost: Double?
    let remainingMinutes: Int?
}
struct StatsBlock: Codable {
    let id: String
    let startTime: String
    let endTime: String
    let actualEndTime: String?
    let isActive: Bool
    let isGap: Bool
    let entries: Int
    let tokenCounts: TokenCounts
    let totalTokens: Int
    let costUSD: Double
    let models: [String]
    let burnRate: BurnRate?
    let projection: Projection?

    // 캐시가 isActive:true로 남아 있어도 윈도우가 이미 지났는지 시각으로 교차검증.
    // endTime 파싱 실패 시(스키마 드리프트) 만료로 단정하지 않음.
    func isExpired(now: Date = Date()) -> Bool {
        guard let e = parseISO8601(endTime) else { return false }
        return now >= e
    }

    // 5시간 블록 경과 비율(0~1) — FiveHourBlock.progress와 동일 개념을 stats-cache 소스에서 파생.
    func elapsedRatio(now: Date = Date()) -> Double {
        guard let s = parseISO8601(startTime), let e = parseISO8601(endTime) else { return 0 }
        let total = e.timeIntervalSince(s)
        guard total > 0 else { return 0 }
        return max(0, min(1, now.timeIntervalSince(s) / total))
    }
}
struct BlocksWrapper: Codable { let blocks: [StatsBlock] }

struct ModelBreakdown: Codable {
    let modelName: String
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheCreationTokens: Int?
    let cacheReadTokens: Int?
    let cost: Double?
    var tokens: Int {
        (inputTokens ?? 0) + (outputTokens ?? 0) + (cacheCreationTokens ?? 0) + (cacheReadTokens ?? 0)
    }
}
struct PeriodStats: Codable {
    let date: String?
    let week: String?
    let month: String?
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheCreationTokens: Int?
    let cacheReadTokens: Int?
    let totalTokens: Int?
    let totalCost: Double?
    let modelsUsed: [String]?
    let modelBreakdowns: [ModelBreakdown]?
}
struct PeriodWrapper: Codable {
    let daily: [PeriodStats]?
    let weekly: [PeriodStats]?
    let monthly: [PeriodStats]?
    let totals: PeriodStats?
}
struct StatsCache: Codable {
    let timestamp: Double?
    let blocks: BlocksWrapper?
    let daily: PeriodWrapper?
    let weekly: PeriodWrapper?
    let monthly: PeriodWrapper?

    // isActive 플래그 + 미만료를 함께 만족하는 블록만 활성으로 채택(stale 캐시 방어).
    func activeBlock(now: Date = Date()) -> StatsBlock? {
        blocks?.blocks.first(where: { $0.isActive && !$0.isExpired(now: now) })
    }

    func todayPeriod() -> PeriodStats? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"   // 1차: 로컬 기준 날짜 매칭
        let local = f.string(from: Date())
        if let hit = daily?.daily?.first(where: { $0.date == local }) { return hit }
        // 폴백: CLI가 daily를 UTC 키로 저장하는 경우 자정 전후 경계 보정
        f.timeZone = TimeZone(identifier: "UTC")
        let utc = f.string(from: Date())
        return daily?.daily?.first(where: { $0.date == utc })
    }

    var cumulative: PeriodStats? { monthly?.totals ?? daily?.totals }
}

final class StatsCacheReader {
    let url: URL
    private var lastMTime: Date?
    private var cached: StatsCache?

    init() {
        url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/stats-cache.json")
    }

    // 파일 없거나 파싱 실패 시 nil → 호출부가 JSONL 폴백으로 분기.
    // mtime 동일하면 직전 디코드 결과 재사용(디코드 생략).
    func load() -> StatsCache? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date else {
            cached = nil; lastMTime = nil
            return nil
        }
        if let last = lastMTime, last == mtime, let c = cached { return c }
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(StatsCache.self, from: data) else {
            return nil   // 디코드 실패 시 캐시 오염 방지
        }
        cached = decoded
        lastMTime = mtime
        return decoded
    }
}

// MARK: - Block Menu Display Model
//
// buildMenu(fromCache:)/buildMenuFromEntries() 공유 뷰모델. 두 데이터 소스(StatsCache 1차 경로
// vs JSONL 폴백)가 실제로 노출하는 필드가 서로 다르므로(예: 캐시 경로는 블록 내 모델별 토큰/비용
// 분해가 없고 모델명만 있음, 폴백 경로는 오늘 섹션에 모델별 분해가 없음) 각 필드를 옵셔널/열거형
// 으로 두어 "있는 그대로" 반영한다 — 두 소스를 인위적으로 대칭시키지 않는다(그렇게 하면 기존
// 표시 내용이 바뀌어 버림).

// StatsBlock 리셋 카운트다운 텍스트 — updateStatusBarTitle(fromCache:)와
// makeBlockDisplayData(fromCache:) 양쪽에서 공유(기존엔 각자 인라인 클로저로 중복 계산).
func resetCountdownText(for b: StatsBlock) -> String {
    if let rm = b.projection?.remainingMinutes { return formatTime(Double(rm) * 60) }
    if let e = parseISO8601(b.endTime) { return formatTime(max(0, e.timeIntervalSinceNow)) }
    return ""
}

struct ModelSectionData {
    enum Shape {
        case namesOnly([String])                                                       // 캐시 경로: 이름만
        case breakdown([(model: String, tokens: Int, cost: Double)], unknownCount: Int) // 폴백 경로: 모델별 분해
    }
    let headerKo: String
    let headerEn: String
    let shape: Shape
}

struct TodaySectionData {
    let totalTokens: Int
    let totalCost: Double
    let messageCount: Int?                                          // 캐시: 미표시(nil), 폴백: 표시(Some)
    let modelBreakdown: [(model: String, tokens: Int, cost: Double)]? // 캐시만 존재
    let hasUsage: Bool
}

struct AllTimeSectionData {
    let totalTokens: Int
    let totalCost: Double
}

struct BlockSectionData {
    let windowText: String?          // "start → end"; nil = 시각 파싱 실패(드문 케이스)
    let outputTokens: Int
    let totalTokens: Int
    let cost: Double
    let messageCount: Int
    let showProgressBar: Bool        // 캐시: start/end 모두 있으면 true. 폴백: remaining>0일 때만 true.
    let progressRatio: Double
    enum ResetState { case remaining(String); case alreadyReset; case none }
    let resetState: ResetState        // "리셋까지"/"블록 리셋됨" 표시 줄
    let warningResetText: String       // "⚠️ 사용량 N% — 남음" 줄 전용(resetState와 별개 — 이미 리셋된
                                       // 경우에도 원본 코드가 0초 텍스트를 그대로 쓰던 동작을 보존)
    let burnRateText: String?         // 캐시 경로만
    let warning: UsageWarning?
    let moodTier: MoodTier?
    let moodRatio: Double
}

struct BlockDisplayData {
    let isEstimate: Bool              // 폴백 경로에서만 true → "추정 모드" 배너
    enum State {
        case noData                   // 폴백 경로 전용
        // 메뉴가 열려 있는 동안 refresh가 진행 중일 때만 쓰는 스켈레톤 상태 — 연관값은 .ready와
        // 완전히 같은 타입이다: 직전 실제 렌더의 값을 그대로 담아두면, 섹션 존재 여부/행 개수 같은
        // "shape"이 이미 그 값들 안에 인코딩되어 있으므로 별도의 shape 전용 구조체가 필요 없다.
        case loading(block: BlockSectionData?, model: ModelSectionData?, today: TodaySectionData, allTime: AllTimeSectionData?)
        case ready(block: BlockSectionData?, model: ModelSectionData?, today: TodaySectionData, allTime: AllTimeSectionData?)
    }
    let state: State
}

extension BlockDisplayData {
    // 직전 .ready 데이터를 .loading으로 재포장 — 노데이터/로딩 중이던 상태에서는 본뜰 shape이
    // 없으므로 nil을 반환한다(호출부가 이 경우 단순 "로딩 중" placeholder로 대체).
    func asLoadingSkeleton() -> BlockDisplayData? {
        guard case .ready(let block, let model, let today, let allTime) = state else { return nil }
        return BlockDisplayData(isEstimate: isEstimate, state: .loading(block: block, model: model, today: today, allTime: allTime))
    }
}

// MARK: - Menu Bar App

class ClaudeMonitorApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    let reader = UsageDataReader()
    let statsReader = StatsCacheReader()
    var lastUpdateTime = Date(timeIntervalSince1970: 0)
    var cachedAll: [UsageEntry] = []
    var cachedStats: StatsCache?
    private(set) var gamificationTodayTokens: Int = 0
    private(set) var gamificationTodayCost: Double = 0
    private(set) var gamificationNewRecordToday: Bool = false
    private(set) var justCrossedTokenMilestone: Int? = nil
    private(set) var justCrossedStreakMilestone: Int? = nil
    // 메뉴바 타이틀에 얹는 축하 배지 — 텍스트를 발화 시점에 캡처해 두고 celebrationBadgeExpiresAt까지
    // 만료 여부만 확인한다(justCrossed*는 다음 refresh()에서 워터마크가 갱신되며 nil로 돌아가므로,
    // 자동 갱신 주기가 배지 지속시간보다 길면 그 사이에 텍스트를 잃어버릴 수 있어 별도 보관 필요).
    private var celebrationBadgeText: String? = nil
    private var celebrationBadgeExpiresAt: Date? = nil
    private var celebrationBadgeTimer: Timer? = nil
    private let celebrationBadgeDuration: TimeInterval = 15
    private var isRefreshing = false
    weak var titleFieldsSubmenu: NSMenu?  // 열려 있는 표시 항목 서브메뉴 — 통째 재구성 없이 행만 갱신하기 위한 참조
    // 아래 6개도 동일한 이유로 유지 — appendFooter()는 이제 obtainMainMenu()가 메인 메뉴 최초
    // 생성 시 딱 1회만 호출하므로 이 weak var들은 그 1회 생성된 인스턴스를 계속 가리킨다.
    weak var separatorSubmenu: NSMenu?
    weak var iconSubmenu: NSMenu?
    weak var moodThemeSubmenu: NSMenu?
    weak var refreshIntervalSubmenu: NSMenu?
    weak var languageSubmenu: NSMenu?
    weak var funModeSubmenu: NSMenu?
    // 메인 5시간 블록 메뉴 — refresh마다 새 NSMenu()로 교체하지 않고 재사용한다. 매번 새 인스턴스를
    // 만들어 statusItem.menu에 재대입하면, 이미 열려(트래킹) 있는 메뉴 인스턴스는 그 재대입의
    // 영향을 받지 않아 사용자가 보는 중엔 갱신되지 않던 문제가 있었다 — 인스턴스를 재사용하고
    // removeAllItems()+재렌더로 항목만 바꿔야 열려 있는 동안에도 반영된다.
    private weak var mainMenu: NSMenu?
    private var mainMenuIsOpen = false  // NSMenuDelegate로 추적 — refresh()가 스켈레톤을 보여줄지 결정
    private var lastBlockDisplayData: BlockDisplayData?  // 스켈레톤 shape의 소스(직전 실제 렌더)
    private var bodyItemCount = 0  // replaceBody(with:)가 이 개수만큼만 메인 메뉴 맨 앞에서 교체한다
    private var footerLocalizedItems: [(NSMenuItem, () -> String)] = []  // 언어 전환 시 footer title 패치용
    private weak var refreshButtonRow: NSMenuItem?  // "지금 새로고침"의 커스텀 뷰 항목 — 언어 전환 시 버튼 타이틀만 따로 patch
    private var coldStartTimer: Timer?  // 콜드 스타트(앱 최초 실행) 전용 로딩 점 순환 애니메이션 — 이후 refresh에는 관여하지 않음
    private var coldStartDotPhase = 0  // 0...3, 표시 폭 고정을 위해 미표시 구간은 공백으로 패딩
    private(set) var flameFlickerTimer: Timer?  // flame/blaze 단계에서만 syncFlameFlickerTimer()가 시작/중지한다
    private var lastMoodTier: MoodTier?  // 흔들림 타이머가 재사용할, 가장 최근 refresh에서 계산된 tier

    func applicationDidFinishLaunching(_ notification: Notification) {
        migrateLegacyDefaultsIfNeeded()
        migrateFunModeIfNeeded()
        NSApp.setActivationPolicy(.accessory)  // Hide from Dock

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        startColdStartAnimation()

        refresh()
        rescheduleTimer()
    }

    // 콜드 스타트 동안만 타이틀/메뉴 헤더에 점 순환("불러오는 중.", "..", "...")을 보여준다. 수동/자동
    // refresh 경로는 건드리지 않는다(기존 설계 의도인 "정보량 없는 반복 깜빡임 방지"를 그대로 유지).
    // renderColdStartFrame()이 replaceBody(_:)를 무조건 1회 호출해 obtainMainMenu()를 통해
    // statusItem.menu를 즉시 부착한다 — 그렇지 않으면 첫 buildMenu()가 끝나기 전까지 메뉴가 없어
    // 콜드 스타트 도중 아이콘 클릭이 무반응이 된다.
    private func startColdStartAnimation() {
        coldStartTimer?.invalidate()
        coldStartDotPhase = 0
        renderColdStartFrame(forceBody: true)  // 최초 1회는 메뉴 부착을 위해 mainMenuIsOpen과 무관하게 렌더
        coldStartTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            self?.tickColdStartAnimation()
        }
    }

    private func tickColdStartAnimation() {
        coldStartDotPhase = (coldStartDotPhase + 1) % 4
        renderColdStartFrame(forceBody: false)
    }

    private func renderColdStartFrame(forceBody: Bool) {
        let dots = String(repeating: ".", count: coldStartDotPhase)
            .padding(toLength: 3, withPad: " ", startingAt: 0)
        renderTitle(plain: "\(titleIconPrefix())\(dots)", warning: nil)
        guard forceBody || mainMenuIsOpen else { return }
        replaceBody { menu in
            self.appendLoadingHeader(menu, dots: dots)
        }
    }

    // 로딩 중 메뉴 헤더("⏳ 불러오는 중...") + 마지막 갱신 시각 라벨 조합 — 콜드 스타트 점 애니메이션과
    // 스켈레톤 폴백(직전 렌더 shape 없음) 양쪽에서 동일한 두 줄 구성을 공유한다.
    private func appendLoadingHeader(_ menu: NSMenu, dots: String) {
        addSectionHeader(menu, t("⏳ 불러오는 중\(dots)", "⏳ Loading\(dots)"))
        appendLastUpdatedLabel(menu)
    }

    // 콜드 스타트 첫 refresh()가 완료되면 애니메이션을 멈춘다 — 두 번째 refresh부터는 이미 nil이라 무해하다.
    private func stopColdStartAnimation() {
        coldStartTimer?.invalidate()
        coldStartTimer = nil
    }

    // 갱신 주기 변경 시 기존 타이머를 무효화하고 새 간격으로 재스케줄
    func rescheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: RefreshSettings.interval().rawValue, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // 읽기는 백그라운드 큐에서, UI 갱신은 메인 큐에서 수행.
    // 1차: stats-cache.json(권위 소스, 비용/토큰). 없으면 JSONL 전량 파싱 폴백.
    // JSONL은 stats-cache 유무와 무관하게 항상 읽는다 — stats-cache의 블록별 models
    // 배열 순서는 "최근 사용순"이 아니라서, 현재 모델 표시는 실제 엔트리 타임스탬프가 필요하다.
    func refresh(manual: Bool = false) {
        if isRefreshing { return }
        isRefreshing = true
        showSkeletonIfMenuOpen()
        if manual {
            // 수동 새로고침은 사용자가 직접 트리거한 행위라 즉각적인 피드백이 유용하다. 자동
            // 백그라운드 틱(10초~5분마다)에는 적용하지 않는다 — 정보량 없이 매번 깜빡이면
            // 예전에 제거한 무드 펄스처럼 산만함만 재도입하게 된다. 예전엔 타이틀 전체를 "…"로
            // 치환해 폭이 흔들렸으나, 텍스트는 그대로 두고 버튼 투명도만 낮춰 폭 변화 없이 "처리
            // 중"을 표시한다 — 아래 완료 시점에 1.0으로 복원.
            statusItem.button?.alphaValue = 0.55
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let stats = self.statsReader.load()
            let entries = self.reader.readAll()
            DispatchQueue.main.async {
                self.cachedStats = stats
                self.cachedAll = entries
                self.lastUpdateTime = Date()
                self.stopColdStartAnimation()  // 콜드 스타트 첫 refresh 완료 — 이후 buildMenu()가 실데이터로 덮어씀
                // 게이미피케이션 기록/이스터에그 워터마크는 항상 재계산한다 — readAll()의 O(N log N)
                // 병합·정렬 스킵과 달리 이 둘은 cachedAll 위 단일 패스 필터/집계라 비용이 낮고 스킵할
                // 근거가 안 된다. updateGamificationRecord()는 "오늘 자정"이라는 벽시계 시각에
                // 의존하므로 JSONL이 하루 종일 안 바뀌어도 자정이 지나면 오늘 토큰/비용을 0으로
                // 리셋해야 하고, updateEasterEggState()의 justCrossed*는 다음 호출에서 스스로 nil로
                // 돌아가는 자기소멸 설계라 게이팅하면 "🎉 마일스톤" 배지가 영구 고정된다.
                self.updateGamificationRecord()
                self.updateEasterEggState()
                self.buildMenu()
                if manual { self.statusItem.button?.alphaValue = 1.0 }
                self.isRefreshing = false
            }
        }
    }

    // 메뉴가 열려 있는 동안 새 refresh 사이클이 시작되면 직전 shape을 본떠 스켈레톤을 1회
    // 그린다. 닫혀 있으면(보는 사람이 없으므로) 아무 것도 하지 않고, 백그라운드 로드가 끝난 뒤
    // buildMenu()가 실제 값으로 조용히 채운다.
    private func showSkeletonIfMenuOpen() {
        guard mainMenuIsOpen else { return }
        replaceBody { menu in
            if let skeleton = self.lastBlockDisplayData?.asLoadingSkeleton() {
                self.renderBlockMenu(skeleton, into: menu)
                self.appendLastUpdatedLabel(menu)
            } else {
                self.appendLoadingHeader(menu, dots: "…")
            }
        }
    }

    // 재미 모드와 무관하게 항상 최신 상태로 갱신한다 — 스트릭은 "실제 사용한 날"을 반영해야 하므로
    // 화면에 안 보인다고 건너뛰면 나중에 재미 모드를 켰을 때 그 사이의 활동이 반영되지 않은 잘못된
    // 갭/리셋이 발생한다. 드롭다운 노출만 TitleSettings.isFunModeFeatureEnabled(.streakSection)으로 게이팅한다.
    func updateGamificationRecord(defaults: UserDefaults = .standard) {
        let todayStart = Calendar.current.startOfDay(for: Date())
        let todayStats = UsageStats(entries: cachedAll.filter { $0.timestamp >= todayStart })
        let today = localDayString(Date())
        let previous = GamificationSettings.load(defaults: defaults)
        let next = computeGamification(previous: previous, today: today,
                                        todayTokens: todayStats.totalTokens, todayCost: todayStats.totalCost)

        gamificationTodayTokens = todayStats.totalTokens
        gamificationTodayCost = todayStats.totalCost
        gamificationNewRecordToday =
            (previous.bestDayTokens > 0 && todayStats.totalTokens >= previous.bestDayTokens) ||
            (previous.bestDayCost   > 0 && todayStats.totalCost   >= previous.bestDayCost)

        if next != previous {
            GamificationSettings.save(next, defaults: defaults)
        }
    }

    // 재미 모드 여부와 무관하게 워터마크는 항상 갱신한다(스트릭/최고기록과 동일한 이유) — 표시가
    // 꺼져 있어도 "이미 넘긴 마일스톤"은 계속 정확히 추적되어야, 나중에 재미 모드를 켰을 때 과거
    // 마일스톤이 몰아서 터지지 않는다. 실제 셀러브레이션 노출만 activeCelebrationBadge()에서 게이팅한다.
    func updateEasterEggState(defaults: UserDefaults = .standard) {
        let lifetimeTokens = UsageStats(entries: cachedAll).totalTokens
        let prevToken = EasterEggSettings.announcedTokenMilestone(defaults: defaults)
        let tokenResult = checkMilestone(currentValue: lifetimeTokens, thresholds: tokenMilestones,
                                          previouslyAnnounced: prevToken)
        if tokenResult.announced != (prevToken ?? -1) {
            EasterEggSettings.setAnnouncedTokenMilestone(tokenResult.announced, defaults: defaults)
        }
        justCrossedTokenMilestone = tokenResult.justCrossed

        let streakDays = GamificationSettings.load(defaults: defaults).currentStreakDays
        let prevStreak = EasterEggSettings.announcedStreakMilestone(defaults: defaults)
        let streakResult = checkMilestone(currentValue: streakDays, thresholds: streakMilestones,
                                           previouslyAnnounced: prevStreak)
        if streakResult.announced != (prevStreak ?? -1) {
            EasterEggSettings.setAnnouncedStreakMilestone(streakResult.announced, defaults: defaults)
        }
        justCrossedStreakMilestone = streakResult.justCrossed

        // 토큰과 스트릭이 같은 사이클에 동시에 터지면(극히 드묾) 토큰 쪽을 우선 노출. 배지 텍스트는
        // 발화 시점에 캡처해 두므로, 자동 갱신 주기가 celebrationBadgeDuration보다 길어 그 사이에
        // justCrossed*가 nil로 돌아가도(워터마크가 이미 전진했으므로) 배지 표시엔 영향 없다.
        if let milestone = tokenResult.justCrossed {
            celebrationBadgeText = t("🎉 \(formatTokens(milestone)) 돌파", "🎉 \(formatTokens(milestone)) reached")
            scheduleCelebrationBadgeExpiry()
        } else if let s = streakResult.justCrossed {
            celebrationBadgeText = t("🔥 \(s)일 연속", "🔥 \(s)-day streak")
            scheduleCelebrationBadgeExpiry()
        }
    }

    // 자동 갱신 주기가 celebrationBadgeDuration보다 길면(예: 5분) refresh()만으로는 배지가 제때
    // 사라지지 않는다 — 만료 시점에 맞춰 짧은 1회성 타이머로 타이틀만 재계산(전체 refresh()는 아님)
    // 해 갱신 주기와 무관하게 정확히 사라지게 한다.
    private func scheduleCelebrationBadgeExpiry() {
        celebrationBadgeExpiresAt = Date().addingTimeInterval(celebrationBadgeDuration)
        celebrationBadgeTimer?.invalidate()
        celebrationBadgeTimer = Timer.scheduledTimer(withTimeInterval: celebrationBadgeDuration, repeats: false) { [weak self] _ in
            self?.updateStatusBarTitle()
        }
    }

    // 재미 모드(마일스톤 축하) ON이고 배지가 아직 만료되지 않았을 때만 non-nil. 타이틀 전체를
    // 대체하지 않고 buildTitleParts() 결과 맨 앞에 얹는 TitlePart라, 실시간 토큰/비용/모델 정보는
    // 배지 노출 중에도 계속 보인다.
    func activeCelebrationBadge() -> TitlePart? {
        guard TitleSettings.isFunModeFeatureEnabled(.celebrations) else { return nil }
        guard let text = celebrationBadgeText, let expires = celebrationBadgeExpiresAt, expires > Date() else { return nil }
        return TitlePart(text: text, color: .green)
    }

    func buildMenu() {
        if let stats = cachedStats {
            buildMenu(fromCache: stats)
        } else {
            buildMenuFromEntries()
        }
    }

    // 메뉴 트리 전체를 재구성하지 않고 상태바 타이틀만 즉시 재계산 — 서브메뉴가 열려 있는 동안의
    // 경량 갱신(refreshTitleFieldsSubmenu())에서 재사용하기 위해 buildMenu(fromCache:)/
    // buildMenuFromEntries()의 타이틀 계산 로직과 분리해 둔다.
    func updateStatusBarTitle() {
        if let stats = cachedStats {
            updateStatusBarTitle(fromCache: stats)
        } else {
            updateStatusBarTitleFromEntries()
        }
    }

    // 재미 모드 OFF면 항상 nil(호출부가 기존 아이콘 로직을 그대로 타게 함). QA 테스트 override는
    // 재미 모드가 켜져 있을 때만 적용된다(꺼짐 상태에서 강제로 무드가 새어 나오지 않도록).
    func resolveMood(hasActiveBlock: Bool, elapsedRatio: Double, warning: UsageWarning?) -> MoodTier? {
        guard TitleSettings.isFunModeFeatureEnabled(.moodIcon) else { return nil }
        return moodTestTierOverride() ?? computeMood(hasActiveBlock: hasActiveBlock, elapsedRatio: elapsedRatio, warning: warning)
    }

    // 실제 tier 재계산 없이 상태바 아이콘만 흔든다 — 타이머 자체의 시작/중지는 applyMood()가 호출하는
    // syncFlameFlickerTimer()가 담당하고, 여기 있는 조건 체크는 그 판단과 어긋나는 상태에서 우연히
    // 한 틱이 더 발생해도(예: invalidate 직후 이미 큐잉된 틱) 안전하게 무시하기 위한 방어적 가드이다.
    private func refreshFlameFlicker() {
        guard TitleSettings.isFunModeFeatureEnabled(.moodIcon),
              TitleSettings.icon() != .none,
              TitleSettings.moodGlyphTheme() == .flame,
              let tier = lastMoodTier,
              flameStage(for: tier) != .ember else { return }
        statusItem.button?.image = moodFlameImage(tier: tier, elapsed: Date().timeIntervalSinceReferenceDate)
    }

    // flame 테마 + 무드 아이콘 on + 아이콘 표시 + 활성 flame/blaze 단계일 때만 타이머를 돌린다. 그 외
    // 조건에서는 타이머 자체를 멈춰 무의미한 5Hz 백그라운드 깨어남을 없앤다. refreshFlameFlicker()의
    // 기존 가드는 안전망(방어적 이중 체크)으로 그대로 둔다.
    private func syncFlameFlickerTimer() {
        let shouldRun = TitleSettings.isFunModeFeatureEnabled(.moodIcon)
            && TitleSettings.icon() != .none
            && TitleSettings.moodGlyphTheme() == .flame
            && (lastMoodTier.map { flameStage(for: $0) != .ember } ?? false)
        if shouldRun {
            guard flameFlickerTimer == nil else { return }
            flameFlickerTimer = Timer.scheduledTimer(withTimeInterval: flameFlickerInterval, repeats: true) { [weak self] _ in
                self?.refreshFlameFlicker()
            }
        } else {
            flameFlickerTimer?.invalidate()
            flameFlickerTimer = nil
        }
    }

    // 무드 tier 변경 시 상태바 아이콘과 lastMoodTier를 항상 함께 갱신하는 단일 진입점 — 흔들림
    // 타이머 시작/중지 판단(syncFlameFlickerTimer())도 여기서 함께 처리해, 향후 호출부가 추가되거나
    // 복붙 실수가 나도 아이콘/lastMoodTier/타이머가 서로 어긋날 위험이 없다.
    func applyMood(_ tier: MoodTier?) {
        lastMoodTier = tier
        // statusItem은 옵셔널 체이닝으로 접근 — 정상 실행 경로에서는 applicationDidFinishLaunching이
        // 항상 먼저 statusItem을 만들어 두므로 실질적으로 nil일 일이 없지만, 셀프테스트가 앱 생명주기
        // 없이 ClaudeMonitorApp() 인스턴스만 만들어 applyMood()를 직접 호출할 수 있게 허용한다(실제
        // NSStatusItem을 생성하면 테스트 실행 중 사용자의 진짜 메뉴바에 아이콘이 나타나므로 피해야 함).
        statusItem?.button?.image = moodImageToApply(tier: tier)
        syncFlameFlickerTimer()
    }

    // buildTitleParts() 결과 맨 앞에 활성 축하 배지(있으면)를 얹는다 — 타이틀을 대체하지 않고
    // 실데이터 파트와 공존시키기 위한 공통 헬퍼.
    private func titlePartsWithBadge(_ ctx: TitleContext) -> [TitlePart] {
        var parts = buildTitleParts(ctx)
        if let badge = activeCelebrationBadge() { parts.insert(badge, at: 0) }
        return parts
    }

    // idle 상태 전용 — 축하 배지도 재미 모드도 없으면 기존 titleIconPrefix() 경로 그대로(바이트 단위
    // 동일), 배지·무드 아이콘 중 하나라도 있으면 TitlePart 배열을 조합해 renderTitle(parts:)로
    // 렌더링한다(사용자가 고른 구분자가 적용됨).
    func renderIdleTitle(_ label: String) {
        let badge = activeCelebrationBadge()
        let moodEnabled = TitleSettings.isFunModeFeatureEnabled(.moodIcon) && TitleSettings.icon() != .none
        // signature/flame 테마가 아니거나 무드가 꺼져 있으면 nil을 대입해 이전 프레임 이미지를 지운다.
        applyMood(moodEnabled ? (moodTestTierOverride() ?? .idle) : nil)
        guard badge != nil || moodEnabled else {
            renderTitle(plain: "\(titleIconPrefix())\(label)", warning: nil)
            return
        }
        var parts: [TitlePart] = []
        if let badge = badge { parts.append(badge) }
        if moodEnabled {
            let tier = moodTestTierOverride() ?? .idle
            if !TitleSettings.moodGlyphTheme().isImageBased {
                parts.append(TitlePart(text: TitleSettings.moodGlyphTheme().glyph(for: tier), color: tier.color))
            }
            parts.append(TitlePart(text: label, color: .defaultColor))
        } else {
            parts.append(TitlePart(text: "\(titleIconPrefix())\(label)".trimmingCharacters(in: .whitespaces), color: .defaultColor))
        }
        renderTitle(parts: parts, warning: nil)
    }

    func updateStatusBarTitle(fromCache stats: StatsCache) {
        let active = stats.activeBlock()
        let warning = active.flatMap { usageWarning(tokens: $0.totalTokens, cost: $0.costUSD) }
        let resetText: String = active.map(resetCountdownText(for:)) ?? ""
        if let b = active {
            // 블록 구간의 실제 JSONL 엔트리(cachedAll)에서 토큰 수 기준으로 가장 많이 쓴 모델을
            // 채택한다. b.models 배열은 CLI가 모델을 처음 발견한 순서라 "최다 사용 모델"이 아닐 수
            // 있으므로 신뢰하지 않는다.
            let start = parseISO8601(b.startTime)
            let end = parseISO8601(b.endTime)
            let topModel: String? = {
                guard let s = start, let e = end else { return nil }
                return mostUsedModel(in: cachedAll.filter { $0.timestamp >= s && $0.timestamp < e })
            }()
            let moodTier = resolveMood(hasActiveBlock: true, elapsedRatio: b.elapsedRatio(), warning: warning)
            applyMood(moodTier)
            let ctx = TitleContext(outputTokens: b.tokenCounts.outputTokens,
                                   totalTokens: b.totalTokens,
                                   cost: b.costUSD,
                                   remainingText: resetText.isEmpty ? nil : resetText,
                                   model: topModel ?? b.models.last,
                                   moodTier: moodTier,
                                   todayTokens: gamificationTodayTokens,
                                   todayCost: gamificationTodayCost,
                                   cumulativeTokens: stats.cumulative?.totalTokens ?? 0)
            renderTitle(parts: titlePartsWithBadge(ctx), warning: warning)
        } else {
            renderIdleTitle(t("유휴", "idle"))
        }
    }

    func updateStatusBarTitleFromEntries() {
        let block = FiveHourBlock.active(from: cachedAll)
        let blockEntries: [UsageEntry]
        if let block = block {
            blockEntries = cachedAll.filter { $0.timestamp >= block.start && $0.timestamp < block.end }
        } else {
            blockEntries = []
        }
        let blockStats = UsageStats(entries: blockEntries)
        let noData = cachedAll.isEmpty && !FileManager.default.fileExists(atPath: reader.projectsDir.path)
        let warning = (block != nil) ? usageWarning(tokens: blockStats.totalTokens, cost: blockStats.totalCost) : nil

        if noData {
            applyMood(nil)
            renderTitle(plain: "\(titleIconPrefix())" + t("데이터 없음", "no data"), warning: nil)
        } else if block == nil {
            renderIdleTitle(t("유휴", "idle"))
        } else if let b = block {
            let moodTier = resolveMood(hasActiveBlock: true, elapsedRatio: b.progress, warning: warning)
            applyMood(moodTier)
            let ctx = TitleContext(outputTokens: blockStats.outputTokens,
                                   totalTokens: blockStats.totalTokens,
                                   cost: blockStats.totalCost,
                                   remainingText: b.remaining > 0 ? formatTime(b.remaining) : nil,
                                   model: mostUsedModel(in: blockEntries), // 블록 내 토큰 수 기준 최다 사용 모델(마지막 사용 모델이 아님)
                                   moodTier: moodTier,
                                   todayTokens: gamificationTodayTokens,
                                   todayCost: gamificationTodayCost,
                                   cumulativeTokens: UsageStats(entries: cachedAll).totalTokens)
            renderTitle(parts: titlePartsWithBadge(ctx), warning: warning)
        }
    }

    // 메인 메뉴가 열리고 닫히는 시점을 추적 — refresh()가 그 사이에 스켈레톤을 보여줄지 판단한다.
    func menuWillOpen(_ menu: NSMenu) {
        if menu === mainMenu { mainMenuIsOpen = true }
    }
    func menuDidClose(_ menu: NSMenu) {
        if menu === mainMenu { mainMenuIsOpen = false }
    }

    // 메인 5시간 블록 메뉴 인스턴스를 최초 1회만 만들고 이후로는 재사용한다. footer(설정
    // 서브메뉴들의 부모 아이템 포함)도 이 최초 생성 시점에 딱 1회만 붙이고 다시는 만들지
    // 않는다 — 그래야 열려 있는 설정 서브메뉴의 부모 NSMenuItem이 어떤 refresh에도 재생성되지
    // 않는다. 이후 모든 갱신은 replaceBody(_:)를 통한 "본문(body)만 교체"로만 이뤄진다.
    private func obtainMainMenu() -> NSMenu {
        if let existing = mainMenu { return existing }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        mainMenu = menu
        statusItem.menu = menu
        appendFooter(menu)
        return menu
    }

    // data를 화면에 붙지 않은 scratch NSMenu에 렌더링한 뒤, 그 안의 NSMenuItem들을 메인 메뉴의
    // 맨 앞(인덱스 0부터)으로 옮겨 끼운다. footer(bodyItemCount 이후의 고정 항목들)는 절대
    // 건드리지 않는다. 다른 메뉴에 이미 속한 NSMenuItem을 곧바로 insertItem하면 크래시하므로,
    // 반드시 scratch.removeItem(item)으로 소유권을 반납한 뒤 삽입해야 한다.
    private func replaceBody(_ render: (NSMenu) -> Void) {
        let menu = obtainMainMenu()
        let scratch = NSMenu()
        render(scratch)

        for _ in 0..<bodyItemCount {
            menu.removeItem(at: 0)
        }
        var count = 0
        while let item = scratch.items.first {
            scratch.removeItem(item)
            menu.insertItem(item, at: count)
            count += 1
        }
        bodyItemCount = count
    }

    // ── 1차 경로: Claude Code stats-cache.json (권위 비용·실제 5시간 블록) ──
    func buildMenu(fromCache stats: StatsCache) {
        updateStatusBarTitle(fromCache: stats)
        let data = makeBlockDisplayData(fromCache: stats)
        lastBlockDisplayData = data
        replaceBody { menu in
            self.renderBlockMenu(data, into: menu)
            self.appendLastUpdatedLabel(menu)
        }
    }

    // ── 1차 경로(stats-cache.json) 뷰모델 어댑터 — 캐시가 노출하지 않는 필드(블록 내 모델별
    // 토큰/비용 분해)는 fromEntries 쪽과 인위적으로 맞추지 않고 있는 그대로(namesOnly) 반영한다. ──
    func makeBlockDisplayData(fromCache stats: StatsCache) -> BlockDisplayData {
        let active = stats.activeBlock()
        let warning = active.flatMap { usageWarning(tokens: $0.totalTokens, cost: $0.costUSD) }

        let block: BlockSectionData?
        if let b = active {
            let start = parseISO8601(b.startTime)
            let end = parseISO8601(b.endTime)
            let windowText: String? = {
                guard let s = start, let e = end else { return nil }
                return "\(formatTimeShort(s)) → \(formatTimeShort(e))"
            }()
            let progressRatio: Double = {
                guard let s = start, let e = end else { return 0 }
                let total = e.timeIntervalSince(s)
                let elapsed = max(0, min(total, Date().timeIntervalSince(s)))
                return total > 0 ? elapsed / total : 0
            }()
            let resetState: BlockSectionData.ResetState = {
                if let rm = b.projection?.remainingMinutes { return .remaining(formatTime(Double(rm) * 60)) }
                if let e = end {
                    let rem = e.timeIntervalSinceNow
                    return rem > 0 ? .remaining(formatTime(rem)) : .alreadyReset
                }
                return .none
            }()
            block = BlockSectionData(
                windowText: windowText,
                outputTokens: b.tokenCounts.outputTokens,
                totalTokens: b.totalTokens,
                cost: b.costUSD,
                messageCount: b.entries,
                showProgressBar: start != nil && end != nil,
                progressRatio: progressRatio,
                resetState: resetState,
                warningResetText: resetCountdownText(for: b),
                burnRateText: b.burnRate?.costPerHour.map { formatCost($0) },
                warning: warning,
                moodTier: resolveMood(hasActiveBlock: true, elapsedRatio: b.elapsedRatio(), warning: warning),
                moodRatio: warning?.ratio ?? b.elapsedRatio()
            )
        } else {
            block = nil
        }

        let model: ModelSectionData?
        if let b = active, !b.models.isEmpty {
            model = ModelSectionData(headerKo: "🤖  모델 (현재 블록)", headerEn: "🤖  Model (Current Block)",
                                      shape: .namesOnly(b.models))
        } else {
            model = nil
        }

        let today: TodaySectionData
        if let t2 = stats.todayPeriod() {
            let breakdown = (t2.modelBreakdowns ?? [])
                .sorted { ($0.cost ?? 0) > ($1.cost ?? 0) }
                .map { (model: shortModelName($0.modelName), tokens: $0.tokens, cost: $0.cost ?? 0) }
            today = TodaySectionData(totalTokens: t2.totalTokens ?? 0, totalCost: t2.totalCost ?? 0,
                                      messageCount: nil, modelBreakdown: breakdown, hasUsage: true)
        } else {
            today = TodaySectionData(totalTokens: 0, totalCost: 0, messageCount: nil, modelBreakdown: nil, hasUsage: false)
        }

        let allTime = stats.cumulative.map { AllTimeSectionData(totalTokens: $0.totalTokens ?? 0, totalCost: $0.totalCost ?? 0) }

        return BlockDisplayData(isEstimate: false, state: .ready(block: block, model: model, today: today, allTime: allTime))
    }

    // ── BlockDisplayData → NSMenu 렌더러. 1차/폴백 경로가 공유하는 유일한 렌더 코드. ──
    func renderBlockMenu(_ data: BlockDisplayData, into menu: NSMenu) {
        switch data.state {
        case .noData:
            addSectionHeader(menu, t("⚠️  데이터 없음", "⚠️  No Data"))
            addLabel(menu, "  " + t("Claude Code를 먼저 실행해 주세요.", "Please run Claude Code first."))
            addLabel(menu, "  " + t("경로: ~/.claude/projects/", "Path: ~/.claude/projects/"))
            menu.addItem(.separator())

        case .loading(let block, let model, let today, let allTime):
            renderBlockSections(block: block, model: model, today: today, allTime: allTime,
                                 isEstimate: data.isEstimate, skeleton: true, into: menu)

        case .ready(let block, let model, let today, let allTime):
            renderBlockSections(block: block, model: model, today: today, allTime: allTime,
                                 isEstimate: data.isEstimate, skeleton: false, into: menu)
        }
    }

    // ── .loading/.ready가 공유하는 렌더러 — skeleton이면 실제 값 대신 회색 placeholder 행을
    // 그린다. 섹션 헤더와 "데이터 없음"류 정적 안내문은 skeleton 여부와 무관하게 항상 실제
    // 텍스트를 쓴다(refresh마다 안 바뀌는 텍스트를 흐리게 하면 레이아웃 점프만 커짐). ──
    private func renderBlockSections(block: BlockSectionData?, model: ModelSectionData?, today: TodaySectionData,
                                      allTime: AllTimeSectionData?, isEstimate: Bool, skeleton: Bool, into menu: NSMenu) {
        if isEstimate {
            addSectionHeader(menu, t("⚠ 추정 모드 — stats-cache.json 없음 (비용은 근사치)", "⚠ Estimate Mode — stats-cache.json missing (costs are approximate)"))
            menu.addItem(.separator())
        }

        // ── 5-Hour Block Section ──
        addSectionHeader(menu, t("⏱  5시간 블록 현황", "⏱  5-Hour Block Status"))
        if let b = block {
            // 재미 모드(무드 아이콘) on/off와 무관하게 항상 계산되는 색 — 색상 코딩은 가독성
            // 기능이지, 재미 모드가 게이팅하는 "기분" 표시 기능이 아니다. resolveMood()는
            // 재미 모드가 꺼져 있으면 항상 nil을 반환하므로 여기서는 쓰지 않고, 그 안에서 쓰는
            // moodTestTierOverride()/computeMood()를 직접 호출해 QA 오버라이드만 재사용한다.
            let heroColor = (moodTestTierOverride()
                ?? computeMood(hasActiveBlock: true, elapsedRatio: b.progressRatio, warning: b.warning)).color.nsColor ?? .labelColor

            switch b.resetState {
            case .remaining(let text):
                skeleton ? addSkeletonLabel(menu, big: true)
                         : addHeroLabel(menu, "  " + t("\(text) 남음", "\(text) remaining"), color: heroColor)
            case .alreadyReset:
                skeleton ? addSkeletonLabel(menu, big: true)
                         : addHeroLabel(menu, "  " + t("✅ 블록 리셋됨 — 새 블록 시작 가능", "✅ Block reset — a new block can start"), color: heroColor)
            case .none:
                break
            }
            if b.showProgressBar {
                skeleton ? addSkeletonLabel(menu)
                         : addColoredLabel(menu, "  " + t("\(progressBar(b.progressRatio, width: 12)) \(Int(b.progressRatio * 100))% 경과", "\(progressBar(b.progressRatio, width: 12)) \(Int(b.progressRatio * 100))% elapsed"), color: heroColor)
            }

            if skeleton {
                addSkeletonLabel(menu)
            } else {
                addLabel(menu, "  " + t("\(formatCost(b.cost)) · \(formatTokens(b.outputTokens)) 출력 / \(formatTokens(b.totalTokens)) 전체 · \(b.messageCount)건",
                                        "\(formatCost(b.cost)) · \(formatTokens(b.outputTokens)) out / \(formatTokens(b.totalTokens)) total · \(b.messageCount) msgs"))
            }

            var windowBurnParts: [String] = []
            if let windowText = b.windowText { windowBurnParts.append(windowText) }
            if let cph = b.burnRateText { windowBurnParts.append(t("소모율 \(cph)/시간", "burn \(cph)/hr")) }
            if !windowBurnParts.isEmpty {
                skeleton ? addSkeletonLabel(menu) : addLabel(menu, "  " + windowBurnParts.joined(separator: " · "))
            }

            if let w = b.warning {
                skeleton ? addSkeletonLabel(menu)
                         : addLabel(menu, "  " + t("사용률: \(Int(w.ratio * 100))% (한도 대비)", "Usage: \(Int(w.ratio * 100))% (of limit)"))
                if w.level != .none {
                    let warnColor: NSColor = (w.level == .crit) ? .systemRed : .systemOrange
                    skeleton ? addSkeletonLabel(menu)
                             : addColoredLabel(menu, "  " + t("⚠️ 사용량 \(Int(w.ratio * 100))% — \(b.warningResetText) 남음", "⚠️ Usage \(Int(w.ratio * 100))% — \(b.warningResetText) remaining"), color: warnColor)
                }
            }
            if let tier = b.moodTier {
                let scopeWord = t(b.warning != nil ? "사용" : "경과", b.warning != nil ? "used" : "elapsed")
                let flameIcon = TitleSettings.moodGlyphTheme() == .flame ? moodFlameImage(tier: tier) : nil
                skeleton ? addSkeletonLabel(menu)
                         : addLabel(menu, "  \(TitleSettings.moodGlyphTheme().glyph(for: tier)) " + t("기분: \(tier.label) (\(Int(b.moodRatio * 100))% \(scopeWord))", "Mood: \(tier.label) (\(Int(b.moodRatio * 100))% \(scopeWord))"), image: flameIcon)
            }
        } else {
            addLabel(menu, "  " + t("현재 활성 블록 없음", "No active block right now"))
            addLabel(menu, "  " + t("다음 메시지부터 새 블록이 시작됩니다.", "A new block will start with your next message."))
        }
        menu.addItem(.separator())

        // ── Model Section ──
        if let model = model {
            addSectionHeader(menu, t(model.headerKo, model.headerEn))
            switch model.shape {
            case .namesOnly(let names):
                for m in names {
                    skeleton ? addSkeletonLabel(menu) : addLabel(menu, "  \(shortModelName(m))")
                }
            case .breakdown(let items, let unknownCount):
                for item in items {
                    skeleton ? addSkeletonLabel(menu)
                             : addLabel(menu, "  \(paddedModelColumn(item.model))  \(formatTokens(item.tokens))  \(formatCost(item.cost))")
                }
                if unknownCount > 0 {
                    skeleton ? addSkeletonLabel(menu)
                             : addLabel(menu, "  " + t("⚠ 미상 모델 \(unknownCount)종 (추정 단가 적용)", "⚠ \(unknownCount) unknown model(s) (estimated pricing applied)"))
                }
            }
            menu.addItem(.separator())
        }

        // ── Today Section ──
        addSectionHeader(menu, t("📅  오늘 (로컬 기준)", "📅  Today (Local Time)"))
        if today.hasUsage {
            skeleton ? addSkeletonLabel(menu) : addLabel(menu, "  " + t("전체 토큰: \(formatTokens(today.totalTokens))", "Total Tokens: \(formatTokens(today.totalTokens))"))
            skeleton ? addSkeletonLabel(menu) : addLabel(menu, "  " + t("예상 비용: \(formatCost(today.totalCost))", "Estimated Cost: \(formatCost(today.totalCost))"))
            if let mc = today.messageCount {
                skeleton ? addSkeletonLabel(menu) : addLabel(menu, "  " + t("메시지 수: \(mc)건", "Messages: \(mc)"))
            }
            for mb in today.modelBreakdown ?? [] {
                skeleton ? addSkeletonLabel(menu) : addLabel(menu, "  \(paddedModelColumn(mb.model))  \(formatTokens(mb.tokens))  \(formatCost(mb.cost))")
            }
        } else {
            addLabel(menu, "  " + t("사용 없음", "No usage"))
        }
        menu.addItem(.separator())

        // ── All-Time Section (캐시 경로는 stats.cumulative 없으면 통째로 생략) ──
        if let allTime = allTime {
            addSectionHeader(menu, t("📊  전체 누적", "📊  All-Time Total"))
            skeleton ? addSkeletonLabel(menu) : addLabel(menu, "  " + t("전체 토큰: \(formatTokens(allTime.totalTokens))", "Total Tokens: \(formatTokens(allTime.totalTokens))"))
            skeleton ? addSkeletonLabel(menu) : addLabel(menu, "  " + t("예상 비용: \(formatCost(allTime.totalCost))", "Estimated Cost: \(formatCost(allTime.totalCost))"))
            menu.addItem(.separator())
        }

        if !skeleton {
            appendGamificationSection(menu)
        }
    }

    // 모델명 컬럼 정렬(오늘 섹션·모델별 분해 섹션 공용)
    private func paddedModelColumn(_ name: String) -> String {
        name.padding(toLength: 12, withPad: " ", startingAt: 0)
    }

    // ── 재미 모드 게이팅된 "🏆 기록" 섹션 — 1차/폴백 메뉴 빌더 양쪽에서 공유(중복 방지) ──
    func appendGamificationSection(_ menu: NSMenu) {
        guard TitleSettings.isFunModeFeatureEnabled(.streakSection) else { return }
        let rec = GamificationSettings.load()
        addSectionHeader(menu, t("🏆  기록", "🏆  Record"))
        let streakLabel = rec.currentStreakDays > 0
            ? t("\(rec.currentStreakDays)일 연속 (최장 \(rec.longestStreakDays)일)",
                "\(rec.currentStreakDays)-day streak (best \(rec.longestStreakDays) days)")
            : t("기록 없음", "No record yet")
        addLabel(menu, "  " + t("연속 사용: \(streakLabel)", "Streak: \(streakLabel)"))
        addLabel(menu, "  " + t("최고 기록: \(formatTokens(rec.bestDayTokens)) · \(formatCost(rec.bestDayCost))",
                                "Best Day: \(formatTokens(rec.bestDayTokens)) · \(formatCost(rec.bestDayCost))"))
        if gamificationNewRecordToday {
            addLabel(menu, "  " + t("📈 오늘 최고 기록 경신", "📈 New personal best today"))
        }
        if let milestone = justCrossedTokenMilestone {
            addLabel(menu, "  " + t("🎉 방금 누적 \(formatTokens(milestone)) 토큰 돌파!", "🎉 Just reached \(formatTokens(milestone)) cumulative tokens!"))
        }
        if let s = justCrossedStreakMilestone {
            addLabel(menu, "  " + t("🔥 방금 \(s)일 연속 사용 달성!", "🔥 Just hit a \(s)-day streak!"))
        }
        menu.addItem(.separator())
    }

    // ── 메뉴 하단 공통(최종 업데이트·새로고침·표시 항목·버전·종료) ──
    // footer는 obtainMainMenu()가 메인 메뉴 최초 생성 시 딱 1회만 호출한다(이후 재호출 없음) —
    // 그래야 여기서 만드는 설정 서브메뉴들의 부모 NSMenuItem이 어떤 refresh에도 재생성되지 않아,
    // 열려 있는 설정 서브메뉴가 자동 갱신 타이머에 영향받지 않는다. 언어처럼 나중에 바뀔 수 있는
    // 텍스트는 track()으로 기억해 두었다가 refreshFooterLocalizedText()가 직접 patch한다.
    func appendFooter(_ menu: NSMenu) {
        func track(_ item: NSMenuItem, _ make: @escaping () -> String) {
            footerLocalizedItems.append((item, make))
        }

        // 커스텀 뷰 항목이라 클릭해도 메뉴가 안 닫힌다(다른 설정 행과 동일한 이유). footer의
        // title 패치 목록(track/footerLocalizedItems)은 NSMenuItem.title을 직접 바꾸는 방식이라
        // .view 기반 항목엔 안 맞으므로, refreshButtonRow로 별도 추적해 버튼 타이틀만 patch한다.
        let refreshMake = { "  🔄 " + t("지금 새로고침", "Refresh Now") }
        let refreshItem = NSMenuItem()
        refreshItem.view = actionRowView(title: refreshMake(), action: #selector(manualRefresh))
        menu.addItem(refreshItem)
        refreshButtonRow = refreshItem

        // 재미 모드를 표시 항목 계열 서브메뉴보다 먼저 배치 — 가장 최근에 추가된 핵심 기능인데
        // 5개 서브메뉴 중 4번째에 묻혀 있으면 발견성이 떨어진다.
        let funModeMake = { "  🎭 " + t("재미 모드", "Fun Mode") }
        let funModeItem = NSMenuItem(title: funModeMake(), action: nil, keyEquivalent: "")
        funModeItem.submenu = obtainFunModeSubmenu()
        menu.addItem(funModeItem)
        track(funModeItem, funModeMake)

        // 무드 아이콘의 모양(테마)을 고르는 서브메뉴 — 무드 아이콘과 관련이 깊어 재미 모드 바로 다음에 배치.
        let moodGlyphThemeMake = { "  🎨 " + t("무드 아이콘 모양", "Mood Icon Style") }
        let moodGlyphThemeItem = NSMenuItem(title: moodGlyphThemeMake(), action: nil, keyEquivalent: "")
        moodGlyphThemeItem.submenu = obtainMoodThemeSubmenu()
        menu.addItem(moodGlyphThemeItem)
        track(moodGlyphThemeItem, moodGlyphThemeMake)

        let titleFieldsMake = { "  ⌨ " + t("메뉴바 표시 항목", "Menu Bar Fields") }
        let titleFieldsItem = NSMenuItem(title: titleFieldsMake(), action: nil, keyEquivalent: "")
        titleFieldsItem.submenu = buildTitleFieldsSubmenu()
        menu.addItem(titleFieldsItem)
        track(titleFieldsItem, titleFieldsMake)

        let separatorMake = { "  ⌇ " + t("표시 항목 구분자", "Field Separator") }
        let separatorItem = NSMenuItem(title: separatorMake(), action: nil, keyEquivalent: "")
        separatorItem.submenu = obtainSeparatorSubmenu()
        menu.addItem(separatorItem)
        track(separatorItem, separatorMake)

        // "메뉴바 표시 항목"과 같은 ⌨ 글리프를 쓰면 두 서브메뉴가 구분되지 않아 🖼로 분리.
        let iconMake = { "  🖼 " + t("메뉴바 아이콘", "Menu Bar Icon") }
        let iconItem = NSMenuItem(title: iconMake(), action: nil, keyEquivalent: "")
        iconItem.submenu = obtainIconSubmenu()
        menu.addItem(iconItem)
        track(iconItem, iconMake)

        let refreshIntervalMake = { "  ⏱ " + t("자동 갱신 주기", "Auto-Refresh Interval") }
        let refreshIntervalItem = NSMenuItem(title: refreshIntervalMake(), action: nil, keyEquivalent: "")
        refreshIntervalItem.submenu = obtainRefreshIntervalSubmenu()
        menu.addItem(refreshIntervalItem)
        track(refreshIntervalItem, refreshIntervalMake)

        let languageMake = { "  🌐 " + t("표시 언어", "Display Language") }
        let languageItem = NSMenuItem(title: languageMake(), action: nil, keyEquivalent: "")
        languageItem.submenu = obtainLanguageSubmenu()
        menu.addItem(languageItem)
        track(languageItem, languageMake)

        menu.addItem(.separator())

        addLabel(menu, "  cc-menutor v\(APP_VERSION)")

        let quitMake = { t("종료", "Quit") }
        let quitItem = NSMenuItem(title: quitMake(), action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        track(quitItem, quitMake)
    }

    // appendFooter에서 분리 — "최종 업데이트" 시각은 매 refresh(스켈레톤 포함)마다 바뀌어야
    // 하므로 body 렌더의 일부로 취급한다. footer는 이제 최초 1회만 만들어지고 다시 그려지지
    // 않기 때문이다.
    private func appendLastUpdatedLabel(_ menu: NSMenu) {
        let updateStr = formatTimeShort(lastUpdateTime)
        addLabel(menu, "  " + t("최종 업데이트: \(updateStr) (\(RefreshSettings.interval().label) 자동 갱신)",
                                "Last Updated: \(updateStr) (auto-refresh every \(RefreshSettings.interval().label))"))
    }

    // 언어 전환 시 footer가 다시 만들어지지 않으므로, appendFooter가 매 refresh마다 재호출되며
    // 암묵적으로 갱신해 주던 것을 대신해 명시적으로 patch한다.
    private func refreshFooterLocalizedText() {
        for (item, make) in footerLocalizedItems { item.title = make() }
        if let button = refreshButtonRow?.view?.subviews.first as? NSButton {
            button.title = "  🔄 " + t("지금 새로고침", "Refresh Now")
        }
        refreshTitleFieldsSubmenu()
        refreshFunModeSubmenu()
        refreshRadioSubmenu(separatorSubmenu, current: TitleSettings.separator(), action: #selector(setSeparatorButton(_:))) { $0.label }
        refreshRadioSubmenu(iconSubmenu, current: TitleSettings.icon(), action: #selector(setIconButton(_:))) { $0.label }
        refreshRadioSubmenu(moodThemeSubmenu, current: TitleSettings.moodGlyphTheme(), action: #selector(setMoodGlyphThemeButton(_:))) { $0.label }
        refreshRadioSubmenu(refreshIntervalSubmenu, current: RefreshSettings.interval(), action: #selector(setRefreshIntervalButton(_:))) { $0.label }
        refreshRadioSubmenu(languageSubmenu, current: TitleSettings.languagePreference(), action: #selector(setLanguagePreferenceButton(_:))) { $0.label }
    }

    // ── 메뉴바 표시 항목 서브메뉴 — 커스텀 NSView 행(체크박스 + ▲/▼) ──
    // 일반 NSMenuItem은 클릭하면 항상 메뉴 트래킹 세션을 끝내고 메뉴 전체를 닫는다.
    // 커스텀 뷰 안의 NSButton은 자체 target-action으로 클릭을 소비하므로 메뉴가 열린 채 유지된다
    // (macOS 볼륨/밝기 슬라이더 등에 쓰이는 표준 패턴).
    func titleFieldRowView(field: TitleField, isFirst: Bool, isLast: Bool) -> NSView {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 246, height: 22))
        let idx = TitleField.allCases.firstIndex(of: field)!  // 순서와 무관한 안정적 식별자

        let checkbox = NSButton(checkboxWithTitle: field.label, target: self, action: #selector(toggleTitleFieldCheckbox(_:)))
        checkbox.frame = NSRect(x: 14, y: 2, width: 150, height: 18)
        checkbox.state = TitleSettings.isEnabled(field) ? .on : .off
        checkbox.tag = idx
        row.addSubview(checkbox)

        let colorButton = NSButton(title: TitleSettings.color(for: field).swatch, target: self, action: #selector(cycleTitleFieldColorButton(_:)))
        colorButton.frame = NSRect(x: 166, y: 1, width: 26, height: 20)
        colorButton.tag = idx
        // 아이콘 전용 버튼(스와치 이모지)이라 VoiceOver가 이모지만 읽으면 무슨 기능인지 알 수 없다.
        colorButton.setAccessibilityLabel(t("\(field.label) 색상 변경", "Change \(field.label) color"))
        row.addSubview(colorButton)

        let up = NSButton(title: "▲", target: self, action: #selector(moveTitleFieldUpButton(_:)))
        up.frame = NSRect(x: 198, y: 1, width: 20, height: 20)
        up.isEnabled = !isFirst
        up.tag = idx
        up.setAccessibilityLabel(t("\(field.label) 위로 이동", "Move \(field.label) up"))
        row.addSubview(up)

        let down = NSButton(title: "▼", target: self, action: #selector(moveTitleFieldDownButton(_:)))
        down.frame = NSRect(x: 220, y: 1, width: 20, height: 20)
        down.isEnabled = !isLast
        down.tag = idx
        down.setAccessibilityLabel(t("\(field.label) 아래로 이동", "Move \(field.label) down"))
        row.addSubview(down)

        return row
    }

    func buildTitleFieldsSubmenu() -> NSMenu {
        let sub = NSMenu()
        let fields = TitleSettings.order()
        for (idx, field) in fields.enumerated() {
            let item = NSMenuItem()
            item.view = titleFieldRowView(field: field, isFirst: idx == 0, isLast: idx == fields.count - 1)
            sub.addItem(item)
        }
        titleFieldsSubmenu = sub
        return sub
    }

    // 메뉴 트리 전체(statusItem.menu)는 건드리지 않고 타이틀과 이 서브메뉴의 행만 갱신 —
    // 그래야 열려 있는 서브메뉴가 buildMenu()의 통째 교체로 인해 닫히지 않는다.
    func refreshTitleFieldsSubmenu() {
        updateStatusBarTitle()
        guard let sub = titleFieldsSubmenu else { return }
        let fields = TitleSettings.order()
        for (idx, item) in sub.items.enumerated() where idx < fields.count {
            item.view = titleFieldRowView(field: fields[idx], isFirst: idx == 0, isLast: idx == fields.count - 1)
        }
    }

    @objc func toggleTitleFieldCheckbox(_ sender: NSButton) {
        TitleSettings.toggle(TitleField.allCases[sender.tag])
        refreshTitleFieldsSubmenu()
    }

    @objc func moveTitleFieldUpButton(_ sender: NSButton) {
        TitleSettings.move(TitleField.allCases[sender.tag], direction: .up)
        refreshTitleFieldsSubmenu()
    }

    @objc func moveTitleFieldDownButton(_ sender: NSButton) {
        TitleSettings.move(TitleField.allCases[sender.tag], direction: .down)
        refreshTitleFieldsSubmenu()
    }

    @objc func cycleTitleFieldColorButton(_ sender: NSButton) {
        TitleSettings.cycleColor(for: TitleField.allCases[sender.tag])
        refreshTitleFieldsSubmenu()
    }

    // 순수 액션 전용 커스텀 뷰(예: "지금 새로고침") — 다른 설정 행과 동일한 이유로 클릭해도
    // 메뉴가 안 닫히게 우회한다. 체크박스/라디오와 달리 상태를 표시하지 않는다.
    private func actionRowView(title: String, action: Selector) -> NSView {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
        let button = NSButton(title: title, target: self, action: action)
        button.frame = NSRect(x: 14, y: 1, width: 200, height: 20)
        row.addSubview(button)
        return row
    }

    // 라디오 스타일 서브메뉴 공용 행 — 표준 NSMenuItem 클릭은 메뉴 트래킹을 끝내버리므로
    // (titleFieldRowView와 동일한 이유), radioButtonWithTitle 하나만 있는 단순 행으로 우회한다.
    private func radioRowView(title: String, isSelected: Bool, tag: Int, action: Selector) -> NSView {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
        let radio = NSButton(radioButtonWithTitle: title, target: self, action: action)
        radio.frame = NSRect(x: 14, y: 2, width: 200, height: 18)
        radio.state = isSelected ? .on : .off
        radio.tag = tag
        row.addSubview(radio)
        return row
    }

    // 기존 buildRadioSubmenu<T>의 커스텀 뷰 버전 — T.allCases를 순회하며 행을 만든다.
    private func buildRadioSubmenuView<T: CaseIterable & Equatable>(
        current: T, action: Selector, title: (T) -> String
    ) -> NSMenu where T.AllCases.Element == T {
        let sub = NSMenu()
        for (idx, value) in T.allCases.enumerated() {
            let item = NSMenuItem()
            item.view = radioRowView(title: title(value), isSelected: value == current, tag: idx, action: action)
            sub.addItem(item)
        }
        return sub
    }

    // refreshTitleFieldsSubmenu()와 동일한 패턴 — 서브메뉴 인스턴스는 그대로 두고 행(item.view)만
    // 다시 그린다. buildMenu()를 호출하지 않으므로 열려 있는 서브메뉴의 트래킹이 깨지지 않는다.
    private func refreshRadioSubmenu<T: CaseIterable & Equatable>(
        _ submenu: NSMenu?, current: T, action: Selector, title: (T) -> String
    ) where T.AllCases.Element == T {
        guard let sub = submenu else { return }
        let values = Array(T.allCases)
        for (idx, item) in sub.items.enumerated() where idx < values.count {
            item.view = radioRowView(title: title(values[idx]), isSelected: values[idx] == current, tag: idx, action: action)
        }
    }

    // ── 표시 항목 구분자 서브메뉴(라디오 스타일 — 하나만 선택) ──
    private func obtainSeparatorSubmenu() -> NSMenu {
        let current = TitleSettings.separator()
        if let existing = separatorSubmenu {
            refreshRadioSubmenu(existing, current: current, action: #selector(setSeparatorButton(_:))) { $0.label }
            return existing
        }
        let sub = buildRadioSubmenuView(current: current, action: #selector(setSeparatorButton(_:))) { $0.label }
        separatorSubmenu = sub
        return sub
    }

    @objc func setSeparatorButton(_ sender: NSButton) {
        let sep = TitleSeparator.allCases[sender.tag]
        TitleSettings.setSeparator(sep)
        updateStatusBarTitle()
        refreshRadioSubmenu(separatorSubmenu, current: sep, action: #selector(setSeparatorButton(_:))) { $0.label }
    }

    // ── 메뉴바 아이콘 서브메뉴(라디오 스타일 — 하나만 선택, "표시 안 함" 포함) ──
    private func obtainIconSubmenu() -> NSMenu {
        let current = TitleSettings.icon()
        if let existing = iconSubmenu {
            refreshRadioSubmenu(existing, current: current, action: #selector(setIconButton(_:))) { $0.label }
            return existing
        }
        let sub = buildRadioSubmenuView(current: current, action: #selector(setIconButton(_:))) { $0.label }
        iconSubmenu = sub
        return sub
    }

    @objc func setIconButton(_ sender: NSButton) {
        let icon = TitleIcon.allCases[sender.tag]
        TitleSettings.setIcon(icon)
        updateStatusBarTitle()
        refreshRadioSubmenu(iconSubmenu, current: icon, action: #selector(setIconButton(_:))) { $0.label }
    }

    // ── 무드 아이콘 모양 서브메뉴(라디오 스타일 — 하나만 선택). 무드 아이콘 토글이 꺼져 있어도
    // 다른 라디오 서브메뉴들과 동일하게 항상 노출한다 — 값을 미리 정해두면 나중에 토글을 켰을 때
    // 그대로 적용된다. ──
    private func obtainMoodThemeSubmenu() -> NSMenu {
        let current = TitleSettings.moodGlyphTheme()
        if let existing = moodThemeSubmenu {
            refreshRadioSubmenu(existing, current: current, action: #selector(setMoodGlyphThemeButton(_:))) { $0.label }
            return existing
        }
        let sub = buildRadioSubmenuView(current: current, action: #selector(setMoodGlyphThemeButton(_:))) { $0.label }
        moodThemeSubmenu = sub
        return sub
    }

    @objc func setMoodGlyphThemeButton(_ sender: NSButton) {
        let theme = MoodGlyphTheme.allCases[sender.tag]
        TitleSettings.setMoodGlyphTheme(theme)
        updateStatusBarTitle()
        refreshRadioSubmenu(moodThemeSubmenu, current: theme, action: #selector(setMoodGlyphThemeButton(_:))) { $0.label }
    }

    // ── 재미 모드 서브메뉴 행 — titleFieldRowView에서 이동/색상 버튼만 제거한 축소판. 라디오와
    // 달리 각 행이 자신의 on/off만 독립적으로 토글한다(하나를 켠다고 다른 게 꺼지지 않음). ──
    private func funModeRowView(feature: FunModeFeature, tag: Int) -> NSView {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
        let checkbox = NSButton(checkboxWithTitle: feature.label, target: self,
                                action: #selector(toggleFunModeFeatureCheckbox(_:)))
        checkbox.frame = NSRect(x: 14, y: 2, width: 200, height: 18)
        checkbox.state = TitleSettings.isFunModeFeatureEnabled(feature) ? .on : .off
        checkbox.tag = tag
        row.addSubview(checkbox)
        return row
    }

    private func buildFunModeSubmenuView() -> NSMenu {
        let sub = NSMenu()
        for (idx, feature) in FunModeFeature.allCases.enumerated() {
            let item = NSMenuItem()
            item.view = funModeRowView(feature: feature, tag: idx)
            sub.addItem(item)
        }
        return sub
    }

    private func refreshFunModeSubmenu() {
        guard let sub = funModeSubmenu else { return }
        let features = Array(FunModeFeature.allCases)
        for (idx, item) in sub.items.enumerated() where idx < features.count {
            item.view = funModeRowView(feature: features[idx], tag: idx)
        }
    }

    private func obtainFunModeSubmenu() -> NSMenu {
        if let existing = funModeSubmenu {
            refreshFunModeSubmenu()
            return existing
        }
        let sub = buildFunModeSubmenuView()
        funModeSubmenu = sub
        return sub
    }

    @objc func toggleFunModeFeatureCheckbox(_ sender: NSButton) {
        let feature = FunModeFeature.allCases[sender.tag]
        TitleSettings.toggleFunModeFeature(feature)
        buildMenu()               // 본문 즉시 재렌더 — moodIcon(기분 줄)·streakSection(🏆 섹션) 반영
        refreshFunModeSubmenu()   // 자기 서브메뉴 체크박스 상태 patch(기존 로직 유지)
    }

    // ── 자동 갱신 주기 서브메뉴(라디오 스타일 — 하나만 선택) ──
    private func obtainRefreshIntervalSubmenu() -> NSMenu {
        let current = RefreshSettings.interval()
        if let existing = refreshIntervalSubmenu {
            refreshRadioSubmenu(existing, current: current, action: #selector(setRefreshIntervalButton(_:))) { $0.label }
            return existing
        }
        let sub = buildRadioSubmenuView(current: current, action: #selector(setRefreshIntervalButton(_:))) { $0.label }
        refreshIntervalSubmenu = sub
        return sub
    }

    @objc func setRefreshIntervalButton(_ sender: NSButton) {
        let interval = RefreshInterval.allCases[sender.tag]
        RefreshSettings.setInterval(interval)
        rescheduleTimer()
        updateStatusBarTitle()
        refreshRadioSubmenu(refreshIntervalSubmenu, current: interval, action: #selector(setRefreshIntervalButton(_:))) { $0.label }
    }

    // ── 표시 언어 서브메뉴(라디오 스타일 — 하나만 선택) ──
    private func obtainLanguageSubmenu() -> NSMenu {
        let current = TitleSettings.languagePreference()
        if let existing = languageSubmenu {
            refreshRadioSubmenu(existing, current: current, action: #selector(setLanguagePreferenceButton(_:))) { $0.label }
            return existing
        }
        let sub = buildRadioSubmenuView(current: current, action: #selector(setLanguagePreferenceButton(_:))) { $0.label }
        languageSubmenu = sub
        return sub
    }

    @objc func setLanguagePreferenceButton(_ sender: NSButton) {
        let pref = LanguagePreference.allCases[sender.tag]
        TitleSettings.setLanguagePreference(pref)
        buildMenu()                    // 본문 전체를 새 언어로 즉시 재렌더
        refreshFooterLocalizedText()   // footer 고정 항목 + 6개 서브메뉴 행 텍스트를 새 언어로 patch
    }

    // ── 폴백 경로: stats-cache.json 부재 시 JSONL 직접 파싱(추정 단가) ──
    func buildMenuFromEntries() {
        updateStatusBarTitleFromEntries()
        let data = makeBlockDisplayData(fromEntries: cachedAll, reader: reader)
        lastBlockDisplayData = data
        replaceBody { menu in
            self.renderBlockMenu(data, into: menu)
            self.appendLastUpdatedLabel(menu)
        }
    }

    // ── 폴백 경로(JSONL 직접 파싱, 추정 단가) 뷰모델 어댑터 ──
    func makeBlockDisplayData(fromEntries cachedAll: [UsageEntry], reader: UsageDataReader) -> BlockDisplayData {
        let noData = cachedAll.isEmpty && !FileManager.default.fileExists(atPath: reader.projectsDir.path)
        if noData {
            return BlockDisplayData(isEstimate: true, state: .noData)
        }

        let activeBlock = FiveHourBlock.active(from: cachedAll)
        let blockEntries: [UsageEntry]
        if let activeBlock = activeBlock {
            blockEntries = cachedAll.filter { $0.timestamp >= activeBlock.start && $0.timestamp < activeBlock.end }
        } else {
            blockEntries = []
        }
        let blockStats = UsageStats(entries: blockEntries)
        let warning = (activeBlock != nil) ? usageWarning(tokens: blockStats.totalTokens, cost: blockStats.totalCost) : nil

        let block: BlockSectionData?
        if let activeBlock = activeBlock {
            let rem = activeBlock.remaining
            block = BlockSectionData(
                windowText: "\(formatTimeShort(activeBlock.start)) → \(formatTimeShort(activeBlock.end))",
                outputTokens: blockStats.outputTokens,
                totalTokens: blockStats.totalTokens,
                cost: blockStats.totalCost,
                messageCount: blockStats.count,
                showProgressBar: rem > 0,
                progressRatio: activeBlock.progress,
                resetState: rem > 0 ? .remaining(formatTime(rem)) : .alreadyReset,
                warningResetText: formatTime(rem),
                burnRateText: nil,
                warning: warning,
                moodTier: resolveMood(hasActiveBlock: true, elapsedRatio: activeBlock.progress, warning: warning),
                moodRatio: warning?.ratio ?? activeBlock.progress
            )
        } else {
            block = nil
        }

        let model: ModelSectionData?
        if !blockStats.modelBreakdown.isEmpty {
            model = ModelSectionData(headerKo: "🤖  모델별 (현재 블록)", headerEn: "🤖  By Model (Current Block)",
                                      shape: .breakdown(blockStats.modelBreakdown, unknownCount: blockStats.unknownModels.count))
        } else {
            model = nil
        }

        let todayStart = Calendar.current.startOfDay(for: Date())
        let todayStats = UsageStats(entries: cachedAll.filter { $0.timestamp >= todayStart })
        let today = TodaySectionData(totalTokens: todayStats.totalTokens, totalCost: todayStats.totalCost,
                                      messageCount: todayStats.count == 0 ? nil : todayStats.count,
                                      modelBreakdown: nil, hasUsage: todayStats.count != 0)

        let allStats = UsageStats(entries: cachedAll)
        let allTime = AllTimeSectionData(totalTokens: allStats.totalTokens, totalCost: allStats.totalCost)

        return BlockDisplayData(isEstimate: true, state: .ready(block: block, model: model, today: today, allTime: allTime))
    }

    // NSMenuItem.isEnabled == false인 표준 아이템은 attributedTitle의 foregroundColor를 무시하고
    // 시스템이 강제로 회색 틴트를 덧씌운다. item.view에 커스텀 NSTextField를 꽂으면 이 표준
    // 제목-그리기 경로 자체를 우회해 지정한 색이 그대로 렌더링된다(titleFieldRowView와 동일 패턴).
    // 행은 NSMenuItem.image가 아니라 커스텀 NSView(row)를 쓰므로, 표준 image 프로퍼티는 AppKit이
    // 무시한다 — image가 있으면 텍스트 필드 앞에 NSImageView를 직접 심어 인셋을 넓힌다.
    private func infoRowItem(_ title: String, font: NSFont, color: NSColor, image: NSImage? = nil) -> NSMenuItem {
        let field = NSTextField(labelWithString: title)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byClipping
        field.sizeToFit()

        var leftInset: CGFloat = 14   // titleFieldRowView의 체크박스 x와 맞춰 다른 행과 정렬
        let rightPad: CGFloat = 6
        let rowHeight = max(18, field.frame.height + 2)
        let iconSize: CGFloat = 12
        let row = NSView(frame: NSRect(x: 0, y: 0,
                                        width: leftInset + (image != nil ? iconSize + 4 : 0) + field.frame.width + rightPad,
                                        height: rowHeight))
        if let image = image {
            let iconView = NSImageView(frame: NSRect(x: leftInset, y: (rowHeight - iconSize) / 2, width: iconSize, height: iconSize))
            iconView.image = image
            row.addSubview(iconView)
            leftInset += iconSize + 4
        }
        field.frame.origin = NSPoint(x: leftInset, y: (rowHeight - field.frame.height) / 2)
        row.addSubview(field)

        let item = NSMenuItem()
        item.view = row
        item.isEnabled = false   // 호버 하이라이트 억제 목적 — 텍스트 색은 field.textColor가 담당
        return item
    }

    func addSectionHeader(_ menu: NSMenu, _ title: String) {
        menu.addItem(infoRowItem(title, font: NSFont.systemFont(ofSize: 11, weight: .semibold), color: .secondaryLabelColor))
    }

    func addLabel(_ menu: NSMenu, _ title: String, image: NSImage? = nil) {
        menu.addItem(infoRowItem(title, font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular), color: .labelColor, image: image))
    }

    // 5시간 블록 섹션에서 가장 중요한 값(남은 시간/리셋 상태)을 다른 줄보다 크고 굵게 강조한다.
    func addHeroLabel(_ menu: NSMenu, _ title: String, color: NSColor) {
        menu.addItem(infoRowItem(title, font: NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .bold), color: color))
    }

    // addLabel과 폰트는 동일하되 색만 지정 — 진행률 바/경고 배너처럼 상태에 따라 색이 바뀌는 줄용.
    func addColoredLabel(_ menu: NSMenu, _ title: String, color: NSColor) {
        menu.addItem(infoRowItem(title, font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular), color: color))
    }

    // 로딩 스켈레톤 전용 — 실제 값 대신 회색 placeholder 막대 하나. addLabel/addHeroLabel과 동일한
    // 폰트 크기를 골라 쓸 수 있게 해(big:) 실제 값이 도착했을 때 행 높이가 흔들리지 않게 한다.
    private func addSkeletonLabel(_ menu: NSMenu, big: Bool = false) {
        let font = big ? NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .bold)
                       : NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        menu.addItem(infoRowItem("  ░░░░░░░░░░░░", font: font, color: .tertiaryLabelColor))
    }

    // 경고 상태면 수치는 유지한 채 ⚠%를 덧붙이고 전체를 색(주황/빨강)으로 덮어써 항목별 색보다 우선시킨다.
    // (남은 시간은 메뉴 안에 표시되므로 타이틀에서는 생략)
    // 평상시엔 항목별 커스텀 색(TitlePart.color)을 적용하되, 항상 attributedTitle을 써서
    // 비포커스 화면(다중 디스플레이)에서 plain title이 자동으로 dim되는 것을 방지한다.
    func renderTitle(parts: [TitlePart], warning: UsageWarning?) {
        guard let button = statusItem.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        if let w = warning, w.level != .none {
            let color: NSColor = (w.level == .crit) ? .systemRed : .systemOrange
            // 색만으로는 색맹 등 일부 사용자에게 "지금 경고 상태"가 전달되지 않을 수 있어
            // 굵기도 함께 올린다(평상시 타이틀은 .regular 그대로 유지).
            let warnFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            let plain = parts.map(\.text).joined(separator: TitleSettings.separator().rawValue)
            let text = "\(plain) ⚠\(Int(w.ratio * 100))%"
            button.attributedTitle = NSAttributedString(string: text, attributes: [
                .font: warnFont,
                .foregroundColor: color
            ])
            return
        }
        let sep = TitleSettings.separator().rawValue
        let result = NSMutableAttributedString()
        for (idx, part) in parts.enumerated() {
            if idx > 0 && !sep.isEmpty {
                result.append(NSAttributedString(string: sep, attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
            }
            result.append(NSAttributedString(string: part.text, attributes: [
                .font: font,
                .foregroundColor: part.color.nsColor ?? NSColor.labelColor
            ]))
        }
        button.attributedTitle = result
    }

    func renderTitle(plain text: String, warning: UsageWarning?) {
        renderTitle(parts: [TitlePart(text: text, color: .defaultColor)], warning: warning)
    }

    @objc func manualRefresh() {
        refresh(manual: true)
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }
}

// MARK: - Self Tests (--test)

func runSelfTests() -> Never {
    var failures = 0
    func check(_ cond: Bool, _ msg: String) {
        if cond { print("  ✓ \(msg)") }
        else { print("  ✗ FAIL: \(msg)"); failures += 1 }
    }
    func entry(_ ts: Date, _ model: String = "claude-sonnet-4-5", out: Int = 0, uuid: String = "") -> UsageEntry {
        UsageEntry(timestamp: ts, model: model, inputTokens: 0, outputTokens: out,
                   cacheReadTokens: 0, cacheWriteTokens: 0, sessionId: "s", uuid: uuid)
    }

    print("Running self-tests...")

    // resolveLanguage (순수 함수)
    check(resolveLanguage(preference: .system, systemLanguageCode: "ko-KR") == .korean,
          "resolveLanguage: system + ko-KR → korean")
    check(resolveLanguage(preference: .system, systemLanguageCode: "en-US") == .english,
          "resolveLanguage: system + en-US → english")
    check(resolveLanguage(preference: .system, systemLanguageCode: "ja-JP") == .english,
          "resolveLanguage: system + 지원 안 하는 로케일(ja-JP) → english 폴백")
    check(resolveLanguage(preference: .system, systemLanguageCode: nil) == .english,
          "resolveLanguage: system + 로케일 없음 → english 폴백")
    check(resolveLanguage(preference: .korean, systemLanguageCode: "en-US") == .korean,
          "resolveLanguage: 명시적 korean은 시스템 로케일 무시")
    check(resolveLanguage(preference: .english, systemLanguageCode: "ko-KR") == .english,
          "resolveLanguage: 명시적 english는 시스템 로케일 무시")

    // TitleSettings.languagePreference (전용 suite)
    let langSuite = "ClaudeMonitorSelfTest.\(UUID().uuidString)"
    if let ld = UserDefaults(suiteName: langSuite) {
        check(TitleSettings.languagePreference(defaults: ld) == .system, "language: 기본값 = system")
        TitleSettings.setLanguagePreference(.english, defaults: ld)
        check(TitleSettings.languagePreference(defaults: ld) == .english, "language: 저장/조회 왕복")
        check(t("한국어", "English", defaults: ld) == "English", "t(): english 설정 시 영어 문자열 반환")
        TitleSettings.setLanguagePreference(.korean, defaults: ld)
        check(t("한국어", "English", defaults: ld) == "한국어", "t(): korean 설정 시 한국어 문자열 반환")
        ld.removePersistentDomain(forName: langSuite)
    } else {
        check(false, "language: 전용 UserDefaults suite 생성 성공해야 함")
    }

    // parseModel / shortModelName
    check(shortModelName("claude-opus-4-1-20250805") == "Opus 4.1", "opus-4-1 → Opus 4.1")
    check(shortModelName("claude-sonnet-4-5-20250929") == "Sonnet 4.5", "sonnet-4-5 → Sonnet 4.5")
    check(shortModelName("claude-3-5-sonnet-20241022") == "Sonnet 3.5", "3-5-sonnet → Sonnet 3.5")
    check(shortModelName("claude-3-opus-20240229") == "Opus 3", "3-opus → Opus 3")
    check(shortModelName("claude-opus-4-8[1m]") == "Opus 4.8", "opus-4-8[1m] → Opus 4.8")
    check(shortModelName("claude-3-5-haiku-20241022") == "Haiku 3.5", "3-5-haiku → Haiku 3.5")

    // mostUsedModel (순수 함수) — 토큰 수 기준 최다 사용 모델, 원본 문자열 유지
    check(mostUsedModel(in: []) == nil, "mostUsedModel: 빈 배열 → nil")

    check(mostUsedModel(in: [entry(Date(), "claude-opus-4-1-20250805", out: 10)])
            == "claude-opus-4-1-20250805",
          "mostUsedModel: 엔트리 1개 → 원본 모델 문자열 그대로 반환(shortModelName 미적용)")

    check(mostUsedModel(in: [
            entry(Date(), "claude-sonnet-4-5", out: 100),
            entry(Date(), "claude-opus-4-1-20250805", out: 10),
            entry(Date(), "claude-opus-4-1-20250805", out: 10),
          ]) == "claude-sonnet-4-5",
          "mostUsedModel: 토큰 합계가 더 큰 모델을 선택(등장 개수가 아닌 토큰 기준)")

    check(mostUsedModel(in: [
            entry(Date(), "claude-sonnet-4-5", out: 30),
            entry(Date(), "claude-opus-4-1-20250805", out: 20),
            entry(Date(), "claude-opus-4-1-20250805", out: 20),
          ]) == "claude-opus-4-1-20250805",
          "mostUsedModel: 같은 모델의 여러 엔트리 토큰을 합산한 뒤 비교(40 > 30)")

    check(mostUsedModel(in: [
            entry(Date(), "claude-opus-4-1-20250805", out: 5),
            entry(Date(), "claude-sonnet-4-5", out: 5),
          ]) == "claude-opus-4-1-20250805",
          "mostUsedModel: 토큰 수 동점이면 모델 문자열 알파벳순으로 결정론적 선택")

    check(mostUsedModel(in: [entry(Date(), "claude-opus-4-1-20250805", out: 1)])
            .map(shortModelName) == "Opus 4.1",
          "mostUsedModel: 결과에 shortModelName()을 적용하면 정상 축약됨(원본 보존 확인, 이중 축약 아님)")

    // getPricing
    check(getPricing(for: "claude-opus-4-1").matched == true, "opus-4-1 정밀 매칭")
    check(getPricing(for: "claude-opus-4-1").pricing.output == 75.0, "opus 출력 단가 75")
    let unknown = getPricing(for: "gpt-4o")
    check(unknown.matched == false, "비-claude 모델 미매칭")
    check(unknown.pricing.output == DEFAULT_PRICING.output, "미상 모델 DEFAULT 단가")

    // cost
    let e = UsageEntry(timestamp: Date(), model: "claude-sonnet-4-5",
                       inputTokens: 1_000_000, outputTokens: 1_000_000,
                       cacheReadTokens: 0, cacheWriteTokens: 0, sessionId: "s", uuid: "")
    check(abs(e.cost - 18.0) < 1e-6, "비용 = input 3 + output 15 = $18")

    // formatters
    check(formatTokens(999) == "999", "formatTokens 999")
    check(formatTokens(1_500) == "1.5K", "formatTokens 1.5K")
    check(formatTokens(2_000_000) == "2.00M", "formatTokens 2.00M")
    check(formatCost(0.005) == "$0.0050", "formatCost 소액 4자리")
    check(formatCost(0.18) == "$0.18", "formatCost 일반")

    // formatTokensStable — 같은 자릿수 구간 내부에서는 항상 동일한 문자 길이(타이틀 폭 고정 검증)
    check(formatTokensStable(5).count == formatTokensStable(999).count,
          "formatTokensStable: 0~999 구간 내부 폭 고정")
    check(formatTokensStable(1_500).count == formatTokensStable(999_900).count,
          "formatTokensStable: K 구간 내부 폭 고정")
    check(formatTokensStable(5) != formatTokensStable(5).trimmingCharacters(in: .whitespaces),
          "formatTokensStable: 짧은 값은 왼쪽 패딩이 실제로 붙음")
    check(formatTokensStable(999_950).hasSuffix("M"),
          "formatTokensStable: 반올림으로 999.9K를 넘는 값(999_950)은 K가 아니라 M 단위로 승격")
    check(formatTokensStable(999_950).count == 7,
          "formatTokensStable: 승격된 M 표시도 7자 폭 고정 유지")
    check(formatTokensStable(999_949).hasSuffix("K"),
          "formatTokensStable: 승격 경계 바로 아래 값은 정상적으로 K 단위 유지")
    check(formatTokensStable(999_999_999).count == 7,
          "formatTokensStable: M 상한 근접 값도 7자 폭 유지(999.99M로 클램프)")

    // String.leftPad
    check("ab".leftPad(to: 5, with: "-") == "---ab", "leftPad: 부족분만큼 왼쪽에 패딩")
    check("abcde".leftPad(to: 3, with: "-") == "abcde", "leftPad: 이미 길면 그대로 반환")

    // FiveHourBlock.active
    let base = Date(timeIntervalSince1970: 1_704_067_200)  // 2024-01-01 00:00:00 UTC
    let h: TimeInterval = 3600

    // 활성 블록: 정시 경계
    if let b = FiveHourBlock.active(
        from: [entry(base), entry(base + h)],
        now: base + 2 * h
    ) {
        check(abs(b.start.timeIntervalSince1970 - base.timeIntervalSince1970) < 1, "블록 시작 = base")
        check(abs(b.end.timeIntervalSince1970 - (base + 5 * h).timeIntervalSince1970) < 1, "블록 끝 = base+5h")
    } else {
        check(false, "활성 블록이 반환되어야 함")
    }

    // floor-to-hour: 00:30 시작 → 블록 시작 00:00
    if let b = FiveHourBlock.active(from: [entry(base + 1800)], now: base + 2 * h) {
        check(abs(b.start.timeIntervalSince1970 - base.timeIntervalSince1970) < 1, "00:30 → floor 00:00")
    } else {
        check(false, "floor 케이스 활성 블록 필요")
    }

    // 유휴: 마지막 활동이 5시간 초과 이전
    check(FiveHourBlock.active(from: [entry(base)], now: base + 6 * h) == nil, "5h 경과 → 유휴(nil)")

    // 5시간 이상 공백 → 새 블록으로 단절
    if let b = FiveHourBlock.active(
        from: [entry(base), entry(base + 6 * h)],
        now: base + 6 * h + 1800
    ) {
        check(abs(b.start.timeIntervalSince1970 - (base + 6 * h).timeIntervalSince1970) < 1, "공백>5h → 새 블록 시작")
    } else {
        check(false, "단절 후 활성 블록 필요")
    }

    // 빈 입력
    check(FiveHourBlock.active(from: [], now: base) == nil, "빈 entries → nil")

    // StatsCache 디코드 (실제 stats-cache.json 구조 픽스처)
    let todayStr: String = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
    }()
    let cacheJSON = """
    {
      "timestamp": 1782808979,
      "blocks": { "blocks": [
        { "id":"b1","startTime":"2026-06-30T05:00:00.000Z","endTime":"2026-06-30T10:00:00.000Z",
          "actualEndTime":"2026-06-30T08:42:38.050Z","isActive":true,"isGap":false,"entries":571,
          "tokenCounts":{"inputTokens":332355,"outputTokens":594516,"cacheCreationInputTokens":4598699,"cacheReadInputTokens":89990316},
          "totalTokens":95515886,"costUSD":84.77,"models":["claude-opus-4-8"],
          "burnRate":{"tokensPerMinute":432984.35,"costPerHour":23.05},
          "projection":{"totalTokens":128871139,"totalCost":114.38,"remainingMinutes":77} }
      ]},
      "daily": { "daily": [
        { "date":"__TODAY__","inputTokens":1,"outputTokens":2,"cacheCreationTokens":3,"cacheReadTokens":4,
          "totalTokens":10,"totalCost":1.5,"modelsUsed":["claude-opus-4-8"],
          "modelBreakdowns":[{"modelName":"claude-opus-4-8","inputTokens":1,"outputTokens":2,"cacheCreationTokens":3,"cacheReadTokens":4,"cost":1.5}] }
      ], "totals": {"totalTokens":999,"totalCost":9.99} },
      "monthly": { "monthly": [], "totals": {"totalTokens":12345,"totalCost":67.89} }
    }
    """.replacingOccurrences(of: "__TODAY__", with: todayStr)
    // 블록 윈도우(05:00~10:00Z) 내부 시각을 주입해 결정적으로 검증
    let inBlock = parseISO8601("2026-06-30T07:00:00.000Z")!
    if let sc = try? JSONDecoder().decode(StatsCache.self, from: Data(cacheJSON.utf8)) {
        check(sc.activeBlock(now: inBlock)?.costUSD == 84.77, "stats: activeBlock costUSD")
        check(sc.activeBlock(now: inBlock)?.tokenCounts.outputTokens == 594516, "stats: activeBlock outputTokens")
        check(sc.activeBlock(now: inBlock)?.projection?.remainingMinutes == 77, "stats: projection remainingMinutes")
        // isActive:true 이지만 endTime(10:00Z) 이후 시각 → stale 캐시로 보고 배제
        check(sc.activeBlock(now: parseISO8601("2026-06-30T11:00:00.000Z")!) == nil, "stats: 만료된 활성 블록 배제(stale)")
        check(sc.todayPeriod()?.totalCost == 1.5, "stats: todayPeriod 날짜 매칭")
        check(sc.todayPeriod()?.modelBreakdowns?.first?.tokens == 10, "stats: modelBreakdown 토큰 합")
        check(sc.cumulative?.totalTokens == 12345, "stats: cumulative = monthly.totals")
    } else {
        check(false, "stats-cache JSON 디코드 성공해야 함")
    }

    // 부분 드리프트 견딤: monthly 없으면 daily.totals 폴백, 활성 블록 없음
    let partialJSON = #"{"blocks":{"blocks":[]},"daily":{"daily":[],"totals":{"totalTokens":5,"totalCost":0.5}}}"#
    if let sc2 = try? JSONDecoder().decode(StatsCache.self, from: Data(partialJSON.utf8)) {
        check(sc2.activeBlock(now: inBlock) == nil, "stats: 활성 블록 없음")
        check(sc2.cumulative?.totalTokens == 5, "stats: monthly 없으면 daily.totals 폴백")
    } else {
        check(false, "부분 캐시 디코드 성공해야 함")
    }

    // 사용량 경고 (computeUsageWarning 순수 함수)
    check(computeUsageWarning(tokens: 100, cost: 1, tokenBudget: 0, costBudget: 0,
                              warnAt: 0.9, critAt: 1.0) == nil, "warn: 한도 0 → 비활성(nil)")
    if let w = computeUsageWarning(tokens: 900, cost: 0, tokenBudget: 1000, costBudget: 0,
                                   warnAt: 0.9, critAt: 1.0) {
        check(w.level == .warn, "warn: 토큰 90% → warn")
        check(abs(w.ratio - 0.9) < 1e-9, "warn: ratio 0.9")
    } else { check(false, "warn: 토큰 90% 경고 반환되어야 함") }
    check(computeUsageWarning(tokens: 500, cost: 0, tokenBudget: 1000, costBudget: 0,
                              warnAt: 0.9, critAt: 1.0)?.level == WarnLevel.none, "warn: 50% → none")
    check(computeUsageWarning(tokens: 0, cost: 12, tokenBudget: 0, costBudget: 10,
                              warnAt: 0.9, critAt: 1.0)?.level == WarnLevel.crit, "warn: 비용 초과 → crit")
    if let w = computeUsageWarning(tokens: 950, cost: 12, tokenBudget: 1000, costBudget: 10,
                                   warnAt: 0.9, critAt: 1.0) {
        check(w.level == .crit, "warn: 토큰95%·비용120% → 더 높은 비율(crit) 채택")
        check(abs(w.ratio - 1.2) < 1e-9, "warn: max ratio = 1.2")
    } else { check(false, "warn: 복합 한도 경고 반환되어야 함") }

    // MoodTier / computeMood (순수 함수 — 재미 모드 무드 아이콘 tier 산출)
    check(computeMood(hasActiveBlock: false, elapsedRatio: 0.99, warning: nil) == .idle, "mood: 비활성 블록 → idle")
    check(computeMood(hasActiveBlock: true, elapsedRatio: 0.0, warning: nil) == .calm, "mood: 0% → calm")
    check(computeMood(hasActiveBlock: true, elapsedRatio: 0.33, warning: nil) == .calm, "mood: 33% → calm")
    check(computeMood(hasActiveBlock: true, elapsedRatio: 0.339, warning: nil) == .calm, "mood: 33.9% → calm")
    check(computeMood(hasActiveBlock: true, elapsedRatio: 0.34, warning: nil) == .warm, "mood: 34% → warm")
    check(computeMood(hasActiveBlock: true, elapsedRatio: 0.66, warning: nil) == .warm, "mood: 66% → warm")
    check(computeMood(hasActiveBlock: true, elapsedRatio: 0.67, warning: nil) == .hot, "mood: 67% → hot")
    check(computeMood(hasActiveBlock: true, elapsedRatio: 0.89, warning: nil) == .hot, "mood: 89% → hot")
    check(computeMood(hasActiveBlock: true, elapsedRatio: 0.90, warning: nil) == .critical, "mood: 90% → critical")
    check(computeMood(hasActiveBlock: true, elapsedRatio: 1.0, warning: nil) == .critical, "mood: 100% → critical")
    check(computeMood(hasActiveBlock: true, elapsedRatio: 1.5, warning: nil) == .critical, "mood: 150%(예산 초과) → critical")
    if let w = computeUsageWarning(tokens: 950, cost: 0, tokenBudget: 1000, costBudget: 0, warnAt: 0.9, critAt: 1.0) {
        check(computeMood(hasActiveBlock: true, elapsedRatio: 0.1, warning: w) == .critical,
              "mood: 예산 설정 시 warning.ratio(0.95)가 elapsedRatio(0.1) 대신 우선 적용")
    } else { check(false, "mood: warning override 테스트용 UsageWarning 생성 실패") }

    // TitleSettings.isFunModeFeatureEnabled / toggleFunModeFeature (전용 UserDefaults suite로 격리)
    let funModeSuite = "ClaudeMonitorSelfTest.\(UUID().uuidString)"
    if let fd = UserDefaults(suiteName: funModeSuite) {
        for feature in FunModeFeature.allCases {
            check(!TitleSettings.isFunModeFeatureEnabled(feature, defaults: fd), "funMode(\(feature.rawValue)): 기본값 = off")
        }
        TitleSettings.setFunModeFeatureEnabled(.moodIcon, true, defaults: fd)
        check(TitleSettings.isFunModeFeatureEnabled(.moodIcon, defaults: fd), "funMode(moodIcon): 저장/조회 왕복")
        check(!TitleSettings.isFunModeFeatureEnabled(.streakSection, defaults: fd), "funMode: 한 기능 on이 다른 기능에 영향 없음(독립 토글)")
        TitleSettings.toggleFunModeFeature(.moodIcon, defaults: fd)
        check(!TitleSettings.isFunModeFeatureEnabled(.moodIcon, defaults: fd), "funMode: toggle이 on → off 전환")
        fd.removePersistentDomain(forName: funModeSuite)
    } else {
        check(false, "funMode: 전용 UserDefaults suite 생성 성공해야 함")
    }

    // migrateFunModeIfNeeded (구 단일 토글 funMode="on" → 3개 플래그 모두 on으로 1회 백필)
    let funModeMigrateSuite = "ClaudeMonitorSelfTest.funModeMigrate.\(UUID().uuidString)"
    if let fmd = UserDefaults(suiteName: funModeMigrateSuite) {
        fmd.set("on", forKey: "funMode")
        migrateFunModeIfNeeded(defaults: fmd)
        for feature in FunModeFeature.allCases {
            check(TitleSettings.isFunModeFeatureEnabled(feature, defaults: fmd), "funMode 마이그레이션: 구 on → \(feature.rawValue) 활성")
        }
        TitleSettings.setFunModeFeatureEnabled(.celebrations, false, defaults: fmd)
        migrateFunModeIfNeeded(defaults: fmd)  // 완료 워터마크 때문에 재호출은 무동작이어야 함
        check(!TitleSettings.isFunModeFeatureEnabled(.celebrations, defaults: fmd), "funMode 마이그레이션: 재호출은 무동작(idempotent)")
        fmd.removePersistentDomain(forName: funModeMigrateSuite)
    } else {
        check(false, "funMode 마이그레이션: 전용 UserDefaults suite 생성 성공해야 함")
    }
    let funModeNoLegacySuite = "ClaudeMonitorSelfTest.funModeMigrate.noLegacy.\(UUID().uuidString)"
    if let fnl = UserDefaults(suiteName: funModeNoLegacySuite) {
        migrateFunModeIfNeeded(defaults: fnl)
        for feature in FunModeFeature.allCases {
            check(!TitleSettings.isFunModeFeatureEnabled(feature, defaults: fnl), "funMode 마이그레이션: 구 설정 없으면 그대로 off")
        }
        fnl.removePersistentDomain(forName: funModeNoLegacySuite)
    } else {
        check(false, "funMode 마이그레이션: no-legacy suite 생성 성공해야 함")
    }

    // computeGamification (순수 함수 — 스트릭/최고 기록 산출)
    let gamDay1 = computeGamification(previous: .empty, today: "2026-06-01", todayTokens: 100, todayCost: 1.0)
    check(gamDay1.currentStreakDays == 1 && gamDay1.longestStreakDays == 1, "gam: 첫 활동 → 스트릭 1")
    check(gamDay1.bestDayTokens == 100 && gamDay1.bestDayCost == 1.0, "gam: 최초 최고 기록 = 오늘 값")

    let gamDay1Again = computeGamification(previous: gamDay1, today: "2026-06-01", todayTokens: 250, todayCost: 2.5)
    check(gamDay1Again.currentStreakDays == 1, "gam: 같은 날 재호출 → 스트릭 불변(멱등)")
    check(gamDay1Again.bestDayTokens == 250, "gam: 같은 날 재호출 → 최고 기록 ratchet")

    let gamDay1Shrink = computeGamification(previous: gamDay1Again, today: "2026-06-01", todayTokens: 10, todayCost: 0.1)
    check(gamDay1Shrink.bestDayTokens == 250, "gam: 최고 기록은 감소하지 않음")

    let gamDay2 = computeGamification(previous: gamDay1Again, today: "2026-06-02", todayTokens: 50, todayCost: 0.5)
    check(gamDay2.currentStreakDays == 2 && gamDay2.longestStreakDays == 2, "gam: 1일 공백 → 스트릭 +1")

    let gamDay5 = computeGamification(previous: gamDay2, today: "2026-06-05", todayTokens: 10, todayCost: 0.1)
    check(gamDay5.currentStreakDays == 1, "gam: 2일 이상 공백 → 스트릭 리셋")
    check(gamDay5.longestStreakDays == 2, "gam: 리셋되어도 최장 기록 보존")

    let gamNoActivity = computeGamification(previous: gamDay2, today: "2026-06-03", todayTokens: 0, todayCost: 0)
    check(gamNoActivity == gamDay2, "gam: 활동 없는 날 → 상태 완전 불변")

    // GamificationSettings 영속화 (전용 UserDefaults suite로 격리)
    let gamSuite = "ClaudeMonitorSelfTest.\(UUID().uuidString)"
    if let gd = UserDefaults(suiteName: gamSuite) {
        check(GamificationSettings.load(defaults: gd) == .empty, "gam: 기본값 = empty")
        GamificationSettings.save(gamDay2, defaults: gd)
        check(GamificationSettings.load(defaults: gd) == gamDay2, "gam: 저장/조회 왕복")
        gd.removePersistentDomain(forName: gamSuite)
    } else {
        check(false, "gam: 전용 UserDefaults suite 생성 성공해야 함")
    }

    // checkMilestone (순수 함수 — 마일스톤 발화 판정)
    let eggBelowAll = checkMilestone(currentValue: 500_000, thresholds: tokenMilestones, previouslyAnnounced: nil)
    check(eggBelowAll.justCrossed == nil, "egg: 최초 실행 & 모든 threshold 미달 → 무음")
    check(eggBelowAll.announced == 0, "egg: 최초 실행 & 모든 threshold 미달 → 워터마크 0으로 백필")

    let eggBackfill = checkMilestone(currentValue: 15_000_000, thresholds: tokenMilestones, previouslyAnnounced: nil)
    check(eggBackfill.justCrossed == nil, "egg: 최초 실행 & 이미 넘은 마일스톤 존재 → 무음 백필(과거분 몰아서 알림 금지)")
    check(eggBackfill.announced == 10_000_000, "egg: 최초 실행 백필 워터마크 = 가장 높은 이미 넘은 단계")

    let eggSingle = checkMilestone(currentValue: 1_200_000, thresholds: tokenMilestones, previouslyAnnounced: 0)
    check(eggSingle.justCrossed == 1_000_000, "egg: 단일 단계 크로싱 → 발화")
    check(eggSingle.announced == 1_000_000, "egg: 발화 시 워터마크 갱신")

    let eggMulti = checkMilestone(currentValue: 15_000_000, thresholds: tokenMilestones, previouslyAnnounced: 0)
    check(eggMulti.justCrossed == 10_000_000, "egg: 한 사이클에 여러 단계 동시 크로싱 → 최고 단계 1회만 발화(1M 건너뛰고 10M)")

    let eggIdempotent = checkMilestone(currentValue: 15_000_000, thresholds: tokenMilestones, previouslyAnnounced: 10_000_000)
    check(eggIdempotent.justCrossed == nil, "egg: 같은/다음 사이클 재확인 → 재발화 없음")
    check(eggIdempotent.announced == 10_000_000, "egg: 워터마크 불변(멱등)")

    let eggRegression = checkMilestone(currentValue: 3, thresholds: streakMilestones, previouslyAnnounced: 7)
    check(eggRegression.justCrossed == nil, "egg: 스트릭 리셋 등 currentValue 하락 → 재발화 없음")
    check(eggRegression.announced == 7, "egg: 워터마크는 감소하지 않음(영구 업적 시맨틱)")

    // EasterEggSettings 영속화 (전용 UserDefaults suite로 격리)
    let eggSuite = "ClaudeMonitorSelfTest.\(UUID().uuidString)"
    if let ed = UserDefaults(suiteName: eggSuite) {
        check(EasterEggSettings.announcedTokenMilestone(defaults: ed) == nil, "egg: 저장 전 토큰 워터마크 = nil(키 부재)")
        check(EasterEggSettings.announcedStreakMilestone(defaults: ed) == nil, "egg: 저장 전 스트릭 워터마크 = nil(키 부재)")
        EasterEggSettings.setAnnouncedTokenMilestone(10_000_000, defaults: ed)
        EasterEggSettings.setAnnouncedStreakMilestone(7, defaults: ed)
        check(EasterEggSettings.announcedTokenMilestone(defaults: ed) == 10_000_000, "egg: 토큰 워터마크 저장/조회 왕복")
        check(EasterEggSettings.announcedStreakMilestone(defaults: ed) == 7, "egg: 스트릭 워터마크 저장/조회 왕복")
        // 0은 "정당한 워터마크"이지 "키 부재"가 아님 — integer(forKey:)였다면 이 구분이 불가능했을 것
        EasterEggSettings.setAnnouncedTokenMilestone(0, defaults: ed)
        check(EasterEggSettings.announcedTokenMilestone(defaults: ed) == 0, "egg: 워터마크 0은 nil과 구분되는 유효값")
        ed.removePersistentDomain(forName: eggSuite)
    } else {
        check(false, "egg: 전용 UserDefaults suite 생성 성공해야 함")
    }

    // buildTitleParts: 무드 아이콘이 정적 아이콘 슬롯을 대체/미대체하는 순수 함수 로직 검증
    // MoodTier.critical.glyph(circles 고정값)와 비교하므로, 실제 사용자가 무드 글리프 테마를
    // bars로 바꿔둔 상태에서도 정확히 통과하도록 강제로 circles로 고정 후 복원한다.
    let savedIconMood = UserDefaults.standard.string(forKey: "titleIcon")
    let savedMoodGlyphThemeForMoodTest = UserDefaults.standard.string(forKey: "moodGlyphTheme")
    TitleSettings.setMoodGlyphTheme(.circles)
    TitleSettings.setIcon(.keyboard)
    let moodCtx = TitleContext(outputTokens: 0, totalTokens: 0, cost: 0, remainingText: nil, model: nil, moodTier: .critical)
    if let moodPart = buildTitleParts(moodCtx).first {
        check(moodPart.text == MoodTier.critical.glyph, "mood: buildTitleParts 첫 파트가 무드 글리프")
        check(moodPart.color == .red, "mood: buildTitleParts 첫 파트 색이 critical(red)")
    } else {
        check(false, "mood: buildTitleParts가 무드 파트를 반환해야 함")
    }
    let noMoodCtx = TitleContext(outputTokens: 0, totalTokens: 0, cost: 0, remainingText: nil, model: nil)
    if let staticPart = buildTitleParts(noMoodCtx).first {
        check(staticPart.text == "⌨", "mood: moodTier nil이면 기존 정적 아이콘 그대로(회귀 가드)")
        check(staticPart.color == .defaultColor, "mood: moodTier nil이면 기본 색(회귀 가드)")
    } else {
        check(false, "mood: buildTitleParts가 아이콘 파트를 반환해야 함")
    }
    TitleSettings.setIcon(.none)
    let hiddenIconCtx = TitleContext(outputTokens: 0, totalTokens: 0, cost: 0, remainingText: nil, model: nil, moodTier: .hot)
    check(!buildTitleParts(hiddenIconCtx).contains(where: { $0.text == MoodTier.hot.glyph }),
          "mood: 아이콘 '표시 안 함'이면 무드 글리프도 함께 숨김")
    if let siMood = savedIconMood { UserDefaults.standard.set(siMood, forKey: "titleIcon") }
    else { UserDefaults.standard.removeObject(forKey: "titleIcon") }
    if let smgt = savedMoodGlyphThemeForMoodTest { UserDefaults.standard.set(smgt, forKey: "moodGlyphTheme") }
    else { UserDefaults.standard.removeObject(forKey: "moodGlyphTheme") }

    // MoodGlyphTheme.glyph(for:) 순수 함수 — 테마 간 구분성 검증
    check(MoodGlyphTheme.bars.glyph(for: .critical) != MoodGlyphTheme.circles.glyph(for: .critical),
          "moodGlyphTheme: bars와 circles는 서로 다른 글리프를 준다")
    check(MoodGlyphTheme.circles.glyph(for: .critical) == MoodTier.critical.glyph,
          "moodGlyphTheme: circles 테마는 MoodTier.glyph와 동일(기본값 하위호환)")

    // buildTitleParts가 선택된 무드 글리프 테마를 반영하는지 (전역 .standard 키를 저장/복원)
    let savedMoodGlyphTheme = UserDefaults.standard.string(forKey: "moodGlyphTheme")
    TitleSettings.setIcon(.keyboard)
    TitleSettings.setMoodGlyphTheme(.bars)
    let barsCtx = TitleContext(outputTokens: 0, totalTokens: 0, cost: 0, remainingText: nil, model: nil, moodTier: .critical)
    check(buildTitleParts(barsCtx).first?.text == "█", "moodGlyphTheme: bars 선택 시 buildTitleParts가 █ 반환")
    TitleSettings.setMoodGlyphTheme(.circles)
    check(buildTitleParts(barsCtx).first?.text == "●", "moodGlyphTheme: circles로 되돌리면 다시 ● 반환")

    // signature 테마: 텍스트 글리프 대신 statusItem.button.image로 렌더링되므로 buildTitleParts는
    // 글리프 텍스트를 만들지 않아야 하고, moodImageToApply()는 조건(테마=signature, 아이콘 표시,
    // tier 존재)이 모두 맞을 때만 이미지를 반환해야 한다.
    TitleSettings.setMoodGlyphTheme(.signature)
    check(!buildTitleParts(barsCtx).contains(where: { $0.text == MoodTier.critical.glyph || $0.text == "█" }),
          "moodGlyphTheme: signature 선택 시 buildTitleParts가 텍스트 글리프를 만들지 않음(이미지로 렌더링)")
    check(moodImageToApply(tier: .critical) != nil,
          "moodImageToApply: signature 테마 + 아이콘 표시 + tier 있음 → 이미지 생성")
    TitleSettings.setMoodGlyphTheme(.circles)
    check(moodImageToApply(tier: .critical) == nil,
          "moodImageToApply: circles 테마면 이미지 없음(nil)")
    TitleSettings.setMoodGlyphTheme(.signature)
    check(moodImageToApply(tier: nil) == nil,
          "moodImageToApply: tier가 nil이면(무드 꺼짐) 이미지 없음")
    TitleSettings.setIcon(.none)
    check(moodImageToApply(tier: .critical) == nil,
          "moodImageToApply: 아이콘 '표시 안 함'이면 signature 테마여도 이미지 없음")
    TitleSettings.setIcon(.keyboard)

    // flame 테마: signature와 동일한 이미지 기반 렌더링 규약을 따라야 한다.
    TitleSettings.setMoodGlyphTheme(.flame)
    check(!buildTitleParts(barsCtx).contains(where: { $0.text == MoodTier.critical.glyph || $0.text == "█" }),
          "moodGlyphTheme: flame 선택 시 buildTitleParts가 텍스트 글리프를 만들지 않음(이미지로 렌더링)")
    check(moodImageToApply(tier: .critical) != nil,
          "moodImageToApply: flame 테마 + 아이콘 표시 + tier 있음 → 이미지 생성")
    check(moodImageToApply(tier: nil) == nil,
          "moodImageToApply: flame 테마여도 tier가 nil이면(무드 꺼짐) 이미지 없음")
    TitleSettings.setIcon(.none)
    check(moodImageToApply(tier: .critical) == nil,
          "moodImageToApply: 아이콘 '표시 안 함'이면 flame 테마여도 이미지 없음")
    TitleSettings.setIcon(.keyboard)

    // FlameStage 그룹핑 불변식 — MoodTier 5단계를 정확히 3개의 아이콘 형태로 묶는지 검증
    check(flameStage(for: .idle) == flameStage(for: .calm), "flameStage: idle과 calm은 같은 불씨 단계")
    check(flameStage(for: .warm) == flameStage(for: .hot), "flameStage: warm과 hot은 같은 불꽃 단계")
    check(flameStage(for: .critical) != flameStage(for: .warm) && flameStage(for: .critical) != flameStage(for: .idle),
          "flameStage: critical은 화염 단계로 별도 분리")
    check(Set(MoodTier.allCases.map(flameStage(for:))).count == 3,
          "flameStage: MoodTier 5단계가 정확히 3개의 아이콘 형태로 묶임")

    // flameSway — 시간에 따라 실제로 값이 변하는 순수 함수인지(흔들림 애니메이션의 기반)
    check(flameSway(elapsed: 0) != flameSway(elapsed: flameFlickerPeriod / 4),
          "flameSway: elapsed가 다르면 다른 흔들림 값을 반환")

    // moodFlameImage(elapsed:) — ember(idle/calm)는 elapsed와 무관하게 완전히 정적이어야 하고,
    // flame/blaze(warm 이상)는 elapsed에 따라 실제로 도형이 달라져야 한다(회귀 방지).
    check(moodFlameImage(tier: .idle, elapsed: 0).tiffRepresentation == moodFlameImage(tier: .idle, elapsed: 1.0).tiffRepresentation,
          "moodFlameImage: ember 단계(idle)는 elapsed가 달라도 이미지가 동일(정적 유지)")
    check(moodFlameImage(tier: .calm, elapsed: 0).tiffRepresentation == moodFlameImage(tier: .calm, elapsed: 1.0).tiffRepresentation,
          "moodFlameImage: ember 단계(calm)는 elapsed가 달라도 이미지가 동일(정적 유지)")
    check(moodFlameImage(tier: .hot, elapsed: 0).tiffRepresentation != moodFlameImage(tier: .hot, elapsed: 1.0).tiffRepresentation,
          "moodFlameImage: flame 단계(hot)는 elapsed에 따라 이미지가 달라짐(흔들림 애니메이션)")
    check(moodFlameImage(tier: .critical, elapsed: 0).tiffRepresentation != moodFlameImage(tier: .critical, elapsed: 1.0).tiffRepresentation,
          "moodFlameImage: blaze 단계(critical)는 elapsed에 따라 이미지가 달라짐(흔들림 애니메이션)")

    // F4 회귀: moodImageToApply()는 elapsed=0 고정 프레임이 아니라 실시간 elapsed를 써야 한다.
    // Date()를 모킹할 수 없어 "실시간 호출 결과가 elapsed=0 정지 프레임과 다르다"로 간접
    // 검증한다 — sin 기반 흔들림 값이 우연히 elapsed=0과 정확히 같은 위상일 확률은 사실상 0이다.
    let restFrame = moodFlameImage(tier: .hot, elapsed: 0)
    let liveFrame = moodImageToApply(tier: .hot)
    check(liveFrame?.tiffRepresentation != restFrame.tiffRepresentation,
          "moodImageToApply: flame/blaze 단계는 elapsed=0 고정 프레임이 아니라 실시간 elapsed 사용")

    // F5 회귀: syncFlameFlickerTimer()가 조건에 따라 타이머를 실제로 시작/중지하는지(정지 상태 =
    // flameFlickerTimer == nil). 이 시점 TitleSettings.icon()은 .keyboard, moodGlyphTheme()은
    // .flame으로 이미 설정돼 있다(위 flame 테마 테스트 블록에서 설정).
    let flickerApp = ClaudeMonitorApp()
    flickerApp.applyMood(.hot)
    check(flickerApp.flameFlickerTimer != nil, "syncFlameFlickerTimer: flame 단계 진입 시 타이머 시작")
    flickerApp.applyMood(.idle)
    check(flickerApp.flameFlickerTimer == nil, "syncFlameFlickerTimer: ember 단계로 돌아가면 타이머 중지")
    flickerApp.applyMood(.critical)
    check(flickerApp.flameFlickerTimer != nil, "syncFlameFlickerTimer: blaze 단계에서도 타이머 시작")
    TitleSettings.setMoodGlyphTheme(.circles)
    flickerApp.applyMood(.critical)
    check(flickerApp.flameFlickerTimer == nil, "syncFlameFlickerTimer: flame 테마가 아니면 tier와 무관하게 타이머 중지")
    flickerApp.flameFlickerTimer?.invalidate()

    if let smgt = savedMoodGlyphTheme { UserDefaults.standard.set(smgt, forKey: "moodGlyphTheme") }
    else { UserDefaults.standard.removeObject(forKey: "moodGlyphTheme") }

    // TitleSettings (전용 UserDefaults suite로 실제 사용자 설정과 격리)
    let titleSuite = "ClaudeMonitorSelfTest.\(UUID().uuidString)"
    if let td = UserDefaults(suiteName: titleSuite) {
        check(TitleSettings.enabledFields(defaults: td) == [.totalTokens, .cost, .remainingTime, .model],
              "title: 기본값 = [블록토큰, 블록비용, 남은시간, 모델명]")
        check(!TitleSettings.isEnabled(.todayTokens, defaults: td)
              && !TitleSettings.isEnabled(.todayCost, defaults: td)
              && !TitleSettings.isEnabled(.cumulativeTokens, defaults: td),
              "title: 오늘/전체 누적 필드는 기본 꺼짐(기존 사용자 화면 불변)")

        TitleSettings.toggle(.outputTokens, defaults: td)  // outputTokens는 기본 비활성
        check(TitleSettings.isEnabled(.outputTokens, defaults: td), "title: 토글로 항목 켜짐")
        TitleSettings.toggle(.outputTokens, defaults: td)
        check(!TitleSettings.isEnabled(.outputTokens, defaults: td), "title: 토글로 항목 꺼짐")

        // 최소 1개 강제: 남은 항목이 1개가 될 때까지 반복해서 끄고, 그 이후로는 해제 불가
        while TitleSettings.enabledFields(defaults: td).count > 1 {
            TitleSettings.toggle(TitleSettings.enabledFields(defaults: td).first!, defaults: td)
        }
        check(TitleSettings.enabledFields(defaults: td).count == 1, "title: 하나만 남을 때까지 끄기 성공")
        let lastField = TitleSettings.enabledFields(defaults: td).first!
        TitleSettings.toggle(lastField, defaults: td)
        check(TitleSettings.isEnabled(lastField, defaults: td), "title: 마지막 1개는 해제 불가")

        td.removePersistentDomain(forName: titleSuite)
    } else {
        check(false, "title: 전용 UserDefaults suite 생성 성공해야 함")
    }

    // buildTitleText (TitleSettings는 .standard를 읽으므로 전역 TitleField/순서/구분자 키를 모두 저장/복원.
    // 순서·구분자는 이 테스트가 검증하려는 대상이 아니므로 고정값으로 강제해 기본값 변경과 무관하게 만든다.)
    let savedTitleDefaults = Dictionary(uniqueKeysWithValues: TitleField.allCases.map {
        ($0, UserDefaults.standard.object(forKey: $0.defaultsKey))
    })
    let savedOrder2 = UserDefaults.standard.array(forKey: "titleFieldsOrder")
    let savedSeparator2 = UserDefaults.standard.string(forKey: "titleSeparator")
    let savedIcon2 = UserDefaults.standard.string(forKey: "titleIcon")
    func setEnabled(_ fields: Set<TitleField>) {
        for f in TitleField.allCases { UserDefaults.standard.set(fields.contains(f), forKey: f.defaultsKey) }
    }
    UserDefaults.standard.set(TitleField.allCases.map(\.rawValue), forKey: "titleFieldsOrder")
    TitleSettings.setSeparator(.space)
    TitleSettings.setIcon(.keyboard)
    let titleCtx = TitleContext(outputTokens: 12_300, totalTokens: 50_000, cost: 4.2,
                                remainingText: nil, model: "claude-sonnet-4-5")
    setEnabled([.outputTokens, .cost])
    check(buildTitleText(titleCtx) == "⌨ \u{2007}12.3K $4.20", "title: outputTokens+cost 조합(formatTokensStable 패딩 반영)")
    setEnabled([.remainingTime])
    check(buildTitleText(titleCtx) == "⌨", "title: 값 없는 필드만 선택 시 ⌨ 단독으로 축소")
    setEnabled([.model])
    check(buildTitleText(titleCtx) == "⌨ Sonnet 4.5", "title: 모델명만 선택")
    let todayCumulativeCtx = TitleContext(outputTokens: 0, totalTokens: 0, cost: 0, remainingText: nil, model: nil,
                                          todayTokens: 128_000, todayCost: 2.5, cumulativeTokens: 5_200_000)
    setEnabled([.todayTokens, .todayCost, .cumulativeTokens])
    check(buildTitleText(todayCumulativeCtx) == "⌨ 128.0K $2.50 \u{2007}\u{2007}5.20M",
          "title: 오늘 토큰+오늘 비용+누적 토큰 조합(formatTokensStable 패딩 반영)")
    for (field, value) in savedTitleDefaults {
        if let v = value { UserDefaults.standard.set(v, forKey: field.defaultsKey) }
        else { UserDefaults.standard.removeObject(forKey: field.defaultsKey) }
    }
    if let so = savedOrder2 { UserDefaults.standard.set(so, forKey: "titleFieldsOrder") }
    else { UserDefaults.standard.removeObject(forKey: "titleFieldsOrder") }
    if let ss = savedSeparator2 { UserDefaults.standard.set(ss, forKey: "titleSeparator") }
    else { UserDefaults.standard.removeObject(forKey: "titleSeparator") }
    if let si = savedIcon2 { UserDefaults.standard.set(si, forKey: "titleIcon") }
    else { UserDefaults.standard.removeObject(forKey: "titleIcon") }

    // TitleSettings.order / move (전용 UserDefaults suite로 격리)
    let orderSuite = "ClaudeMonitorSelfTest.\(UUID().uuidString)"
    if let od = UserDefaults(suiteName: orderSuite) {
        let defaultOrderExpected: [TitleField] = [.model, .totalTokens, .cost, .remainingTime, .outputTokens,
                                                    .todayTokens, .todayCost, .cumulativeTokens]
        check(TitleSettings.order(defaults: od) == defaultOrderExpected,
              "order: 기본값 = [모델명,블록토큰,블록비용,남은시간,블록출력토큰,오늘토큰,오늘비용,누적토큰]")
        // defaultOrder는 TitleField.allCases와 별도로 하드코딩된 목록이라, 새 필드를 추가하고
        // 여기 반영을 깜빡하면 order()가 그 필드를 영영 반환하지 않는다(설정 서브메뉴에도 안 나타남).
        // 매번 정확한 순서를 손으로 나열하지 않아도 최소한 "다 포함은 됐는지"는 이 회귀 가드가 잡는다.
        check(Set(TitleSettings.order(defaults: od)) == Set(TitleField.allCases),
              "order: 기본 순서가 TitleField.allCases를 전부 포함(신규 필드 defaultOrder 누락 방지)")

        TitleSettings.move(.cost, direction: .up, defaults: od)
        check(TitleSettings.order(defaults: od) == [.model, .cost, .totalTokens, .remainingTime, .outputTokens,
                                                      .todayTokens, .todayCost, .cumulativeTokens],
              "order: cost를 위로 이동 → totalTokens와 스왑")

        // 경계 무시: 맨 위 항목을 위로, 맨 아래 항목을 아래로 이동해도 무변화
        let before = TitleSettings.order(defaults: od)
        TitleSettings.move(before.first!, direction: .up, defaults: od)
        TitleSettings.move(before.last!, direction: .down, defaults: od)
        check(TitleSettings.order(defaults: od) == before, "order: 경계에서 이동 시도는 무시됨")

        // enabledFieldsInOrder: 기본 활성 항목 하나(remainingTime)를 꺼서 필터링이 순서를 유지한 채 동작하는지 확인
        TitleSettings.toggle(.remainingTime, defaults: od)
        check(TitleSettings.enabledFieldsInOrder(defaults: od) == [.model, .cost, .totalTokens],
              "order: enabledFieldsInOrder는 활성 필드만 현재 순서대로 반환")
        od.removePersistentDomain(forName: orderSuite)
    } else {
        check(false, "order: 전용 UserDefaults suite 생성 성공해야 함")
    }

    // TitleSettings.separator (전용 suite)
    let sepSuite = "ClaudeMonitorSelfTest.\(UUID().uuidString)"
    if let sd = UserDefaults(suiteName: sepSuite) {
        check(TitleSettings.separator(defaults: sd) == .dot, "separator: 기본값 = 가운데점")
        TitleSettings.setSeparator(.pipe, defaults: sd)
        check(TitleSettings.separator(defaults: sd) == .pipe, "separator: 저장/조회 왕복")
        sd.removePersistentDomain(forName: sepSuite)
    } else {
        check(false, "separator: 전용 UserDefaults suite 생성 성공해야 함")
    }

    // TitleSettings.icon (전용 suite)
    let iconSuite = "ClaudeMonitorSelfTest.\(UUID().uuidString)"
    if let ic = UserDefaults(suiteName: iconSuite) {
        check(TitleSettings.icon(defaults: ic) == .keyboard, "icon: 기본값 = 키보드")
        TitleSettings.setIcon(.robot, defaults: ic)
        check(TitleSettings.icon(defaults: ic) == .robot, "icon: 저장/조회 왕복")
        ic.removePersistentDomain(forName: iconSuite)
    } else {
        check(false, "icon: 전용 UserDefaults suite 생성 성공해야 함")
    }

    // TitleSettings.moodGlyphTheme (전용 suite)
    let moodGlyphThemeSuite = "ClaudeMonitorSelfTest.\(UUID().uuidString)"
    if let mgt = UserDefaults(suiteName: moodGlyphThemeSuite) {
        check(TitleSettings.moodGlyphTheme(defaults: mgt) == .circles, "moodGlyphTheme: 기본값 = 원형")
        TitleSettings.setMoodGlyphTheme(.bars, defaults: mgt)
        check(TitleSettings.moodGlyphTheme(defaults: mgt) == .bars, "moodGlyphTheme: 저장/조회 왕복")
        mgt.removePersistentDomain(forName: moodGlyphThemeSuite)
    } else {
        check(false, "moodGlyphTheme: 전용 UserDefaults suite 생성 성공해야 함")
    }
    let savedIcon3 = UserDefaults.standard.string(forKey: "titleIcon")
    TitleSettings.setIcon(.keyboard)
    check(titleIconPrefix() == "⌨ ", "icon: titleIconPrefix 기본 아이콘")
    TitleSettings.setIcon(.none)
    check(titleIconPrefix() == "", "icon: titleIconPrefix 표시 안 함")
    if let si3 = savedIcon3 { UserDefaults.standard.set(si3, forKey: "titleIcon") }
    else { UserDefaults.standard.removeObject(forKey: "titleIcon") }

    // TitleSettings.color (전용 suite)
    let colorSuite = "ClaudeMonitorSelfTest.\(UUID().uuidString)"
    if let cd = UserDefaults(suiteName: colorSuite) {
        check(TitleSettings.color(for: .cost, defaults: cd) == .defaultColor, "color: 기본값 = defaultColor")
        TitleSettings.setColor(.red, for: .cost, defaults: cd)
        check(TitleSettings.color(for: .cost, defaults: cd) == .red, "color: 저장/조회 왕복")
        TitleSettings.cycleColor(for: .cost, defaults: cd)
        check(TitleSettings.color(for: .cost, defaults: cd) == .orange, "color: cycleColor는 팔레트의 다음 색으로 이동")
        check(TitleFieldColor.gray.next == .defaultColor, "color: 팔레트 마지막(gray) 다음은 defaultColor로 순환")
        cd.removePersistentDomain(forName: colorSuite)
    } else {
        check(false, "color: 전용 UserDefaults suite 생성 성공해야 함")
    }

    // RefreshSettings.interval (전용 suite)
    let refreshSuite = "ClaudeMonitorSelfTest.\(UUID().uuidString)"
    if let rd = UserDefaults(suiteName: refreshSuite) {
        check(RefreshSettings.interval(defaults: rd) == .sec30, "refresh: 기본값 = 30초")
        RefreshSettings.setInterval(.min1, defaults: rd)
        check(RefreshSettings.interval(defaults: rd) == .min1, "refresh: 저장/조회 왕복")
        rd.removePersistentDomain(forName: refreshSuite)
    } else {
        check(false, "refresh: 전용 UserDefaults suite 생성 성공해야 함")
    }

    // buildTitleText: 커스텀 구분자 + 순서 + 아이콘 조합 (전역 .standard 키를 저장/복원 — enabled 상태도 포함)
    let savedOrder = UserDefaults.standard.array(forKey: "titleFieldsOrder")
    let savedSeparator = UserDefaults.standard.string(forKey: "titleSeparator")
    let savedIcon4 = UserDefaults.standard.string(forKey: "titleIcon")
    let savedEnabled2 = Dictionary(uniqueKeysWithValues: TitleField.allCases.map {
        ($0, UserDefaults.standard.object(forKey: $0.defaultsKey))
    })
    let savedCostColor = UserDefaults.standard.string(forKey: "titleColor_cost")
    let savedModelColor = UserDefaults.standard.string(forKey: "titleColor_model")
    setEnabled([.outputTokens, .cost, .model])
    UserDefaults.standard.set(["model", "cost", "outputTokens"], forKey: "titleFieldsOrder")
    TitleSettings.setIcon(.keyboard)
    TitleSettings.setSeparator(.pipe)
    check(buildTitleText(titleCtx) == "⌨ | Sonnet 4.5 | $4.20 | \u{2007}12.3K",
          "title: 커스텀 순서(model→cost→outputTokens) + 구분자(|) 조합")
    TitleSettings.setSeparator(.none)
    check(buildTitleText(titleCtx) == "⌨Sonnet 4.5$4.20\u{2007}12.3K", "title: 구분자 없음 조합")
    TitleSettings.setIcon(.robot)
    TitleSettings.setSeparator(.space)
    check(buildTitleText(titleCtx) == "🤖 Sonnet 4.5 $4.20 \u{2007}12.3K", "title: 커스텀 아이콘(로봇) 조합")
    TitleSettings.setIcon(.none)
    check(buildTitleText(titleCtx) == "Sonnet 4.5 $4.20 \u{2007}12.3K", "title: 아이콘 없음 — 선행 구분자 없이 첫 필드부터 시작")
    TitleSettings.setColor(.blue, for: .cost)
    UserDefaults.standard.removeObject(forKey: "titleColor_model")  // 이 검증은 model이 미지정(defaultColor)임을 전제로 함
    let coloredParts = buildTitleParts(titleCtx)
    check(coloredParts.first(where: { $0.text == "$4.20" })?.color == .blue,
          "buildTitleParts: 지정한 필드(cost)에 커스텀 색이 붙는다")
    check(coloredParts.first(where: { $0.text == "Sonnet 4.5" })?.color == .defaultColor,
          "buildTitleParts: 색을 지정하지 않은 필드(model)는 defaultColor 유지")
    if let sc = savedCostColor { UserDefaults.standard.set(sc, forKey: "titleColor_cost") }
    else { UserDefaults.standard.removeObject(forKey: "titleColor_cost") }
    if let smc = savedModelColor { UserDefaults.standard.set(smc, forKey: "titleColor_model") }
    else { UserDefaults.standard.removeObject(forKey: "titleColor_model") }
    if let so = savedOrder { UserDefaults.standard.set(so, forKey: "titleFieldsOrder") }
    else { UserDefaults.standard.removeObject(forKey: "titleFieldsOrder") }
    if let ss = savedSeparator { UserDefaults.standard.set(ss, forKey: "titleSeparator") }
    else { UserDefaults.standard.removeObject(forKey: "titleSeparator") }
    if let si4 = savedIcon4 { UserDefaults.standard.set(si4, forKey: "titleIcon") }
    else { UserDefaults.standard.removeObject(forKey: "titleIcon") }
    for (field, value) in savedEnabled2 {
        if let v = value { UserDefaults.standard.set(v, forKey: field.defaultsKey) }
        else { UserDefaults.standard.removeObject(forKey: field.defaultsKey) }
    }

    // acquireSingleInstanceLock (실제 ~/.cc-menutor.lock 대신 임시 경로 사용)
    let lockTestPath = NSTemporaryDirectory() + "ClaudeMonitorSelfTest-\(UUID().uuidString).lock"
    check(acquireSingleInstanceLock(path: lockTestPath), "lock: 첫 획득 성공")
    check(!acquireSingleInstanceLock(path: lockTestPath), "lock: 동일 파일 재획득 실패(중복 인스턴스 차단)")
    try? FileManager.default.removeItem(atPath: lockTestPath)

    // UsageDataReader.readAll() — 파일 변경 없는 사이클에서 전체 재병합/재정렬을 스킵하는지
    // (성능 최적화 회귀 테스트). 실제 홈 디렉터리 대신 임시 디렉터리를 주입해 격리한다.
    do {
        let readerHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ClaudeMonitorSelfTest.reader.\(UUID().uuidString)")
        let projectDir = readerHome.appendingPathComponent(".claude/projects/proj1")
        try? FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let sessionFile = projectDir.appendingPathComponent("session1.jsonl")

        func line(uuid: String, ts: String, outputTokens: Int) -> String {
            "{\"type\":\"assistant\",\"uuid\":\"\(uuid)\",\"timestamp\":\"\(ts)\"," +
            "\"message\":{\"model\":\"claude-sonnet-5\",\"usage\":{\"input_tokens\":10,\"output_tokens\":\(outputTokens)}}}\n"
        }

        try? (line(uuid: "a", ts: "2026-01-01T00:00:00Z", outputTokens: 100))
            .write(to: sessionFile, atomically: true, encoding: .utf8)

        let reader = UsageDataReader(homeDir: readerHome)
        let first = reader.readAll()
        check(first.count == 1 && first.first?.outputTokens == 100,
              "readAll: 첫 호출은 파일을 파싱해 엔트리를 반환")
        check(reader.lastReadChanged, "readAll: 첫 호출은 lastReadChanged == true")

        let second = reader.readAll()
        check(second.map { $0.uuid } == first.map { $0.uuid },
              "readAll: 파일 변경 없는 2차 호출도 동일한 엔트리를 반환(재병합 스킵해도 결과 불변)")
        check(!reader.lastReadChanged,
              "readAll: 파일 변경 없으면 lastReadChanged == false(전체 재병합/재정렬 스킵)")

        if let handle = try? FileHandle(forWritingTo: sessionFile) {
            handle.seekToEndOfFile()
            handle.write((line(uuid: "b", ts: "2026-01-01T00:05:00Z", outputTokens: 200)).data(using: .utf8)!)
            try? handle.close()
        }
        let third = reader.readAll()
        check(third.count == 2, "readAll: 파일에 줄 추가 후 3차 호출은 신규 엔트리를 포함")
        check(reader.lastReadChanged, "readAll: 파일이 바뀌면 lastReadChanged가 다시 true로 복귀")

        try? FileManager.default.removeItem(at: readerHome)
    }

    // F1 회귀: refresh()가 entriesChanged와 무관하게 updateGamificationRecord()/
    // updateEasterEggState()를 항상 호출해야 하는지 뒷받침하는 두 함수 자체의 동작 검증. 전용
    // UserDefaults(suiteName:)로 격리해 실사용자 스트릭/마일스톤 상태를 절대 건드리지 않는다.
    let f1GamSuite = "ClaudeMonitorSelfTest.gam.\(UUID().uuidString)"
    if let gd = UserDefaults(suiteName: f1GamSuite) {
        let gamApp = ClaudeMonitorApp()
        let pastDate = Date(timeIntervalSince1970: 1_600_000_000)  // 2020년 — "오늘"이 아님
        gamApp.cachedAll = [UsageEntry(timestamp: pastDate, model: "claude-sonnet-5",
                                        inputTokens: 0, outputTokens: 500, cacheReadTokens: 0, cacheWriteTokens: 0,
                                        sessionId: "s1", uuid: "u1")]
        gamApp.updateGamificationRecord(defaults: gd)
        check(gamApp.gamificationTodayTokens == 0,
              "updateGamificationRecord: cachedAll에 '오늘' 엔트리가 없으면 오늘 토큰은 0")

        gamApp.updateEasterEggState(defaults: gd)  // 최초 호출 — 아직 마일스톤 미달, 베이스라인만 기록
        gamApp.cachedAll.append(UsageEntry(timestamp: pastDate, model: "claude-sonnet-5",
                                            inputTokens: 0, outputTokens: 1_500_000, cacheReadTokens: 0, cacheWriteTokens: 0,
                                            sessionId: "s1", uuid: "u2"))
        gamApp.updateEasterEggState(defaults: gd)
        check(gamApp.justCrossedTokenMilestone == 1_000_000,
              "updateEasterEggState: 마일스톤을 실제로 넘기면 justCrossed에 해당 임계값 설정")

        gamApp.updateEasterEggState(defaults: gd)  // 동일 상태로 재호출
        check(gamApp.justCrossedTokenMilestone == nil,
              "updateEasterEggState: 재호출 시 자기소멸(nil로 복귀) — entriesChanged 게이팅이 되살아나면 이 회귀가 깨짐")
    }

    // migrateLegacyDefaultsIfNeeded (전용 legacy/new suite 쌍으로 격리 — 실제 ClaudeMonitor 도메인은 건드리지 않음)
    let legacySuite = "ClaudeMonitorSelfTest.legacy.\(UUID().uuidString)"
    let newSuite = "ClaudeMonitorSelfTest.new.\(UUID().uuidString)"
    if let legacy = UserDefaults(suiteName: legacySuite), let new = UserDefaults(suiteName: newSuite) {
        legacy.set(true, forKey: TitleField.outputTokens.defaultsKey)
        legacy.set("blue", forKey: "titleColor_cost")
        legacy.set(["cost", "model"], forKey: "titleFieldsOrder")
        new.set(false, forKey: TitleField.model.defaultsKey)  // 새 도메인에 이미 있는 값은 보존돼야 함

        migrateLegacyDefaultsIfNeeded(defaults: new, legacyDefaults: legacy)
        check(new.bool(forKey: TitleField.outputTokens.defaultsKey), "migrate: 구 도메인 값이 새 도메인으로 복사됨")
        check(new.string(forKey: "titleColor_cost") == "blue", "migrate: 필드별 색상 키도 복사됨")
        check((new.array(forKey: "titleFieldsOrder") as? [String]) == ["cost", "model"], "migrate: 순서 키도 복사됨")
        check(new.bool(forKey: TitleField.model.defaultsKey) == false, "migrate: 새 도메인에 이미 있던 값은 덮어쓰지 않음")

        legacy.set(false, forKey: TitleField.outputTokens.defaultsKey)
        migrateLegacyDefaultsIfNeeded(defaults: new, legacyDefaults: legacy)  // 1회만 동작해야 함
        check(new.bool(forKey: TitleField.outputTokens.defaultsKey), "migrate: 재호출은 무동작(idempotent)")

        legacy.removePersistentDomain(forName: legacySuite)
        new.removePersistentDomain(forName: newSuite)
    } else {
        check(false, "migrate: 전용 UserDefaults suite 쌍 생성 성공해야 함")
    }
    let noLegacySuite = "ClaudeMonitorSelfTest.migrate.noLegacy.\(UUID().uuidString)"
    if let nl = UserDefaults(suiteName: noLegacySuite) {
        migrateLegacyDefaultsIfNeeded(defaults: nl, legacyDefaults: nil)
        check(nl.bool(forKey: legacyMigrationDoneKey), "migrate: legacy 도메인 없어도 완료 플래그는 남겨 재시도 방지")
        nl.removePersistentDomain(forName: noLegacySuite)
    } else {
        check(false, "migrate: no-legacy suite 생성 성공해야 함")
    }

    if failures == 0 {
        print("All tests passed. ✅")
        exit(0)
    } else {
        print("\(failures) test(s) failed. ❌")
        exit(1)
    }
}

// MARK: - Single Instance Guard
//
// 이 앱은 번들 ID가 없는 bare 실행 파일이라 NSRunningApplication 번들 기반 중복 체크를 쓸 수 없다.
// flock은 파일 디스크립터 단위로 걸리고 프로세스 종료 시 커널이 자동 해제하므로,
// PID 파일 방식과 달리 크래시로 인한 스테일 락이 남지 않는다.

import Darwin

let defaultLockPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".cc-menutor.lock").path

// fd는 의도적으로 닫지 않는다 — 락은 프로세스 생존 동안 유지되어야 하며 종료 시 커널이 자동 해제한다.
func acquireSingleInstanceLock(path: String = defaultLockPath) -> Bool {
    let fd = open(path, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { return true }  // 락 파일 자체를 못 열면(권한 등) 차단하지 않고 통과
    return flock(fd, LOCK_EX | LOCK_NB) == 0
}

// MARK: - Entry Point

if CommandLine.arguments.contains("--test") {
    runSelfTests()
}

guard acquireSingleInstanceLock() else {
    FileHandle.standardError.write("이미 실행 중인 인스턴스가 있어 종료합니다.\n".data(using: .utf8)!)
    exit(0)
}

let app = NSApplication.shared
let delegate = ClaudeMonitorApp()
app.delegate = delegate
app.run()
