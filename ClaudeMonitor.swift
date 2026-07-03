// ClaudeMonitor.swift
// Claude Code 5시간 블록 사용량 메뉴바 모니터
// Build:   swiftc -module-cache-path /tmp/swiftcache -o ClaudeMonitor ClaudeMonitor.swift -framework Cocoa
// Run:     ./ClaudeMonitor
// Test:    ./ClaudeMonitor --test
// Requires: macOS 12+, Claude Code CLI (https://claude.ai/code)

import Cocoa
import Foundation

let APP_VERSION = "1.4"

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
    case moodIcon, streakSection, celebrations, refreshFlash

    var label: String {
        switch self {
        case .moodIcon:      return t("무드 아이콘", "Mood Icon")
        case .streakSection: return t("연속 사용 기록", "Streak Record")
        case .celebrations:  return t("마일스톤 축하", "Milestone Celebrations")
        case .refreshFlash:  return t("새로고침 반짝임", "Refresh Sparkle")
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

    init() {
        homeDir = FileManager.default.homeDirectoryForCurrentUser
    }

    var projectsDir: URL { homeDir.appendingPathComponent(".claude/projects") }

    // 변경된 파일의 신규 줄만 읽어 누적. 메인스레드 외(백그라운드 큐)에서 호출됨.
    func readAll() -> [UsageEntry] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: projectsDir.path) else {
            fileCache.removeAll()
            cachedEntries = []
            return []
        }

        guard let enumerator = fm.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var present = Set<String>()

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            let path = fileURL.path
            present.insert(path)

            let size = UInt64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)

            // 크기 동일 → 변경 없음, 캐시 재사용 (파일 미오픈)
            if let cached = fileCache[path], cached.size == size { continue }

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
        }

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

// MARK: - Formatters

func formatTokens(_ n: Int) -> String {
    switch n {
    case 0..<1_000:     return "\(n)"
    case 0..<1_000_000: return String(format: "%.1fK", Double(n) / 1_000)
    default:            return String(format: "%.2fM", Double(n) / 1_000_000)
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

// 무드 글리프의 "모양" 테마 — 색(TitleFieldColor)은 테마와 무관하게 MoodTier.color 그대로 쓴다.
// 자유 텍스트 입력을 허용하지 않는 이유: 컬러 프레젠테이션 이모지를 넣으면 위 색상 틴팅이 조용히
// 먹히지 않기 때문에(:712 주석 참고), 색 틴팅이 검증된 텍스트 프레젠테이션 글리프로만 구성된
// 테마 중에서 고르게 한다.
enum MoodGlyphTheme: String, CaseIterable {
    case circles, bars

    var label: String {
        switch self {
        case .circles: return t("○ 원형 (기본)", "○ Circles (Default)")
        case .bars:    return t("▁ 막대", "▁ Bars")
        }
    }

    func glyph(for tier: MoodTier) -> String {
        switch self {
        case .circles:
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
    let moodPulsePhase: Bool     // 무드 글리프 맥박 애니메이션의 현재 프레임(true = 강조 프레임)
    let todayTokens: Int
    let todayCost: Double
    let cumulativeTokens: Int

    // moodTier/moodPulsePhase 이후 추가되는 필드는 전부 기본값을 줘 기존 호출부가 그대로 컴파일되게 한다.
    init(outputTokens: Int, totalTokens: Int, cost: Double, remainingText: String?, model: String?,
         moodTier: MoodTier? = nil, moodPulsePhase: Bool = false,
         todayTokens: Int = 0, todayCost: Double = 0, cumulativeTokens: Int = 0) {
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.cost = cost
        self.remainingText = remainingText
        self.model = model
        self.moodTier = moodTier
        self.moodPulsePhase = moodPulsePhase
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

struct TitlePart { let text: String; let color: TitleFieldColor; var pulsing: Bool = false }

func buildTitleParts(_ ctx: TitleContext) -> [TitlePart] {
    var parts: [TitlePart] = []
    // ctx.moodTier는 재미 모드 ON일 때만 non-nil — OFF면 기존처럼 정적 TitleIcon을 그대로 사용해
    // 출력이 이전과 동일함을 보장한다. 사용자가 아이콘을 "표시 안 함"으로 두면 무드도 함께 숨긴다.
    if TitleSettings.icon() != .none {
        if let tier = ctx.moodTier {
            parts.append(TitlePart(text: TitleSettings.moodGlyphTheme().glyph(for: tier), color: tier.color, pulsing: ctx.moodPulsePhase))
        } else {
            let icon = TitleSettings.icon().rawValue
            if !icon.isEmpty { parts.append(TitlePart(text: icon, color: .defaultColor)) }
        }
    }
    for field in TitleSettings.enabledFieldsInOrder() {
        switch field {
        case .outputTokens:     parts.append(TitlePart(text: formatTokens(ctx.outputTokens), color: TitleSettings.color(for: field)))
        case .totalTokens:      parts.append(TitlePart(text: formatTokens(ctx.totalTokens), color: TitleSettings.color(for: field)))
        case .cost:             parts.append(TitlePart(text: formatCost(ctx.cost), color: TitleSettings.color(for: field)))
        case .remainingTime:    if let r = ctx.remainingText { parts.append(TitlePart(text: r, color: TitleSettings.color(for: field))) }
        case .model:            if let m = ctx.model { parts.append(TitlePart(text: shortModelName(m), color: TitleSettings.color(for: field))) }
        case .todayTokens:      parts.append(TitlePart(text: formatTokens(ctx.todayTokens), color: TitleSettings.color(for: field)))
        case .todayCost:        parts.append(TitlePart(text: formatCost(ctx.todayCost), color: TitleSettings.color(for: field)))
        case .cumulativeTokens: parts.append(TitlePart(text: formatTokens(ctx.cumulativeTokens), color: TitleSettings.color(for: field)))
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
        case ready(block: BlockSectionData?, model: ModelSectionData?, today: TodaySectionData, allTime: AllTimeSectionData?)
    }
    let state: State
}

// MARK: - Menu Bar App

class ClaudeMonitorApp: NSObject, NSApplicationDelegate {
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
    // 무드 아이콘 맥박 애니메이션 — 활성 블록이 있고 무드 아이콘이 켜져 있을 때만 도는 경량 타이머.
    // moodPulsePhase를 뒤집고 updateStatusBarTitle()만 재호출(전체 refresh()는 아님)해 데이터
    // 갱신 주기(10초~5분)와 무관하게 짧은 주기로 돈다.
    private var moodPulseTimer: Timer? = nil
    private var moodPulsePhase = false
    private let moodPulseInterval: TimeInterval = 1.0
    // 자동/수동 새로고침 직후 잠깐 나타났다 사라지는 반짝임 — celebrationBadge와 동일한
    // "일회성 타이머로 만료 시점에 updateStatusBarTitle()만 재호출" 패턴.
    private var refreshFlashExpiresAt: Date? = nil
    private var refreshFlashTimer: Timer? = nil
    private let refreshFlashDuration: TimeInterval = 1.5
    private var isRefreshing = false
    weak var titleFieldsSubmenu: NSMenu?  // 열려 있는 표시 항목 서브메뉴 — 통째 재구성 없이 행만 갱신하기 위한 참조

    func applicationDidFinishLaunching(_ notification: Notification) {
        migrateLegacyDefaultsIfNeeded()
        migrateFunModeIfNeeded()
        NSApp.setActivationPolicy(.accessory)  // Hide from Dock

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        renderTitle(plain: "\(titleIconPrefix())…", warning: nil)

        refresh()
        rescheduleTimer()
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
    func refresh() {
        if isRefreshing { return }
        isRefreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let stats = self.statsReader.load()
            let entries = self.reader.readAll()
            DispatchQueue.main.async {
                self.cachedStats = stats
                self.cachedAll = entries
                self.lastUpdateTime = Date()
                self.updateGamificationRecord()
                self.updateEasterEggState()
                self.scheduleRefreshFlash()
                self.buildMenu()
                self.isRefreshing = false
            }
        }
    }

    // 재미 모드와 무관하게 항상 최신 상태로 갱신한다 — 스트릭은 "실제 사용한 날"을 반영해야 하므로
    // 화면에 안 보인다고 건너뛰면 나중에 재미 모드를 켰을 때 그 사이의 활동이 반영되지 않은 잘못된
    // 갭/리셋이 발생한다. 드롭다운 노출만 TitleSettings.isFunModeFeatureEnabled(.streakSection)으로 게이팅한다.
    func updateGamificationRecord() {
        let todayStart = Calendar.current.startOfDay(for: Date())
        let todayStats = UsageStats(entries: cachedAll.filter { $0.timestamp >= todayStart })
        let today = localDayString(Date())
        let previous = GamificationSettings.load()
        let next = computeGamification(previous: previous, today: today,
                                        todayTokens: todayStats.totalTokens, todayCost: todayStats.totalCost)

        gamificationTodayTokens = todayStats.totalTokens
        gamificationTodayCost = todayStats.totalCost
        gamificationNewRecordToday =
            (previous.bestDayTokens > 0 && todayStats.totalTokens >= previous.bestDayTokens) ||
            (previous.bestDayCost   > 0 && todayStats.totalCost   >= previous.bestDayCost)

        if next != previous {
            GamificationSettings.save(next)
        }
    }

    // 재미 모드 여부와 무관하게 워터마크는 항상 갱신한다(스트릭/최고기록과 동일한 이유) — 표시가
    // 꺼져 있어도 "이미 넘긴 마일스톤"은 계속 정확히 추적되어야, 나중에 재미 모드를 켰을 때 과거
    // 마일스톤이 몰아서 터지지 않는다. 실제 셀러브레이션 노출만 activeCelebrationBadge()에서 게이팅한다.
    func updateEasterEggState() {
        let lifetimeTokens = UsageStats(entries: cachedAll).totalTokens
        let prevToken = EasterEggSettings.announcedTokenMilestone()
        let tokenResult = checkMilestone(currentValue: lifetimeTokens, thresholds: tokenMilestones,
                                          previouslyAnnounced: prevToken)
        if tokenResult.announced != (prevToken ?? -1) {
            EasterEggSettings.setAnnouncedTokenMilestone(tokenResult.announced)
        }
        justCrossedTokenMilestone = tokenResult.justCrossed

        let streakDays = GamificationSettings.load().currentStreakDays
        let prevStreak = EasterEggSettings.announcedStreakMilestone()
        let streakResult = checkMilestone(currentValue: streakDays, thresholds: streakMilestones,
                                           previouslyAnnounced: prevStreak)
        if streakResult.announced != (prevStreak ?? -1) {
            EasterEggSettings.setAnnouncedStreakMilestone(streakResult.announced)
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

    // celebrationBadge와 동일한 구조 — 자동 갱신 주기가 refreshFlashDuration(1.5초)보다 훨씬 길
    // 수 있으므로(최대 5분), 만료 시점에 맞춰 짧은 1회성 타이머로 타이틀만 재계산해 정확히 사라지게
    // 한다. refresh()가 다시 일어나 만료 전에 재호출되면 만료 시각을 매번 갱신하므로(재호출 시
    // 이전 타이머는 invalidate) 연속 갱신 중에도 자연스럽게 이어져 보인다.
    private func scheduleRefreshFlash() {
        // 꺼져 있으면 아예 스케줄하지 않는다 — 반짝임은 축하 배지의 마일스톤 워터마크처럼 꺼진
        // 동안에도 정확히 추적해야 할 장기 상태가 없는 순수 코스메틱이라, 매 refresh()마다 불필요한
        // 타이머를 만들 이유가 없다.
        guard TitleSettings.isFunModeFeatureEnabled(.refreshFlash) else { return }
        refreshFlashExpiresAt = Date().addingTimeInterval(refreshFlashDuration)
        refreshFlashTimer?.invalidate()
        refreshFlashTimer = Timer.scheduledTimer(withTimeInterval: refreshFlashDuration, repeats: false) { [weak self] _ in
            self?.updateStatusBarTitle()
        }
    }

    // 재미 모드(새로고침 반짝임) ON이고 아직 만료되지 않았을 때만 non-nil. 타이틀 끝에 덧붙이는
    // TitlePart라 실데이터(아이콘/무드/필드)는 그대로 보이고 끝에 ✨만 잠깐 얹힌다.
    func activeRefreshFlash() -> TitlePart? {
        guard TitleSettings.isFunModeFeatureEnabled(.refreshFlash) else { return nil }
        guard let expires = refreshFlashExpiresAt, expires > Date() else { return nil }
        return TitlePart(text: "✨", color: .defaultColor)
    }

    // 무드 아이콘이 켜져 있고 "볼 대상"(활성 블록, 또는 QA용 CLAUDE_MONITOR_MOOD_TEST_TIER 오버라이드)이
    // 있을 때만 펄스 타이머를 돌린다. 유휴 상태에서 의미 없이 깜빡이는 걸 피해 배터리·시각적 산만함을
    // 줄인다. 이미 원하는 상태면 아무 것도 하지 않아(멱등) 매 렌더마다 타이머를 재생성하지 않는다.
    // 호출부(updateStatusBarTitle(fromCache:)/FromEntries())가 ctx를 만들기 전에 먼저 불러야
    // moodPulsePhase 리셋이 뒤이은 렌더에 반영된다 — 여기서 직접 updateStatusBarTitle()을 다시
    // 부르면 그 호출부와 서로를 무한 재귀로 부르게 되므로 재렌더는 호출부에 맡긴다.
    private func updateMoodPulseTimerState(hasActiveMoodTarget: Bool) {
        let shouldRun = TitleSettings.isFunModeFeatureEnabled(.moodIcon) && hasActiveMoodTarget
        if shouldRun {
            guard moodPulseTimer == nil else { return }
            moodPulseTimer = Timer.scheduledTimer(withTimeInterval: moodPulseInterval, repeats: true) { [weak self] _ in
                self?.moodPulsePhase.toggle()
                self?.updateStatusBarTitle()
            }
        } else {
            guard moodPulseTimer != nil else { return }
            moodPulseTimer?.invalidate()
            moodPulseTimer = nil
            moodPulsePhase = false
        }
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

    // buildTitleParts() 결과 맨 앞에 활성 축하 배지(있으면)를 얹는다 — 타이틀을 대체하지 않고
    // 실데이터 파트와 공존시키기 위한 공통 헬퍼.
    private func titlePartsWithBadge(_ ctx: TitleContext) -> [TitlePart] {
        var parts = buildTitleParts(ctx)
        if let badge = activeCelebrationBadge() { parts.insert(badge, at: 0) }
        if let flash = activeRefreshFlash() { parts.append(flash) }
        return parts
    }

    // idle 상태 전용 — 축하 배지도 재미 모드도 없으면 기존 titleIconPrefix() 경로 그대로(바이트 단위
    // 동일), 배지·무드 아이콘 중 하나라도 있으면 TitlePart 배열을 조합해 renderTitle(parts:)로
    // 렌더링한다(사용자가 고른 구분자가 적용됨).
    func renderIdleTitle(_ label: String) {
        let badge = activeCelebrationBadge()
        let flash = activeRefreshFlash()
        let moodEnabled = TitleSettings.isFunModeFeatureEnabled(.moodIcon) && TitleSettings.icon() != .none
        guard badge != nil || flash != nil || moodEnabled else {
            renderTitle(plain: "\(titleIconPrefix())\(label)", warning: nil)
            return
        }
        var parts: [TitlePart] = []
        if let badge = badge { parts.append(badge) }
        if moodEnabled {
            let tier = moodTestTierOverride() ?? .idle
            parts.append(TitlePart(text: TitleSettings.moodGlyphTheme().glyph(for: tier), color: tier.color, pulsing: moodPulsePhase))
            parts.append(TitlePart(text: label, color: .defaultColor))
        } else {
            parts.append(TitlePart(text: "\(titleIconPrefix())\(label)".trimmingCharacters(in: .whitespaces), color: .defaultColor))
        }
        if let flash = flash { parts.append(flash) }
        renderTitle(parts: parts, warning: nil)
    }

    func updateStatusBarTitle(fromCache stats: StatsCache) {
        let active = stats.activeBlock()
        // QA 오버라이드가 있으면 실제 활성 블록이 없어도(idle) 펄스를 미리 볼 수 있게 한다.
        updateMoodPulseTimerState(hasActiveMoodTarget: active != nil || moodTestTierOverride() != nil)
        let warning = active.flatMap { usageWarning(tokens: $0.totalTokens, cost: $0.costUSD) }
        let resetText: String = active.map(resetCountdownText(for:)) ?? ""
        if let b = active {
            // b.models.last는 CLI가 모델을 처음 발견한 순서라 "최근 사용 모델"이 아닐 수 있다.
            // 실제 JSONL 엔트리(시간순 정렬됨)에서 블록 구간 내 마지막 모델을 우선 사용.
            let start = parseISO8601(b.startTime)
            let end = parseISO8601(b.endTime)
            let lastModel: String? = {
                guard let s = start, let e = end else { return nil }
                return cachedAll.filter { $0.timestamp >= s && $0.timestamp < e }.last?.model
            }()
            let moodTier = resolveMood(hasActiveBlock: true, elapsedRatio: b.elapsedRatio(), warning: warning)
            let ctx = TitleContext(outputTokens: b.tokenCounts.outputTokens,
                                   totalTokens: b.totalTokens,
                                   cost: b.costUSD,
                                   remainingText: resetText.isEmpty ? nil : resetText,
                                   model: lastModel ?? b.models.last,
                                   moodTier: moodTier,
                                   moodPulsePhase: moodPulsePhase,
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
        updateMoodPulseTimerState(hasActiveMoodTarget: block != nil || moodTestTierOverride() != nil)
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
            renderTitle(plain: "\(titleIconPrefix())" + t("데이터 없음", "no data"), warning: nil)
        } else if block == nil {
            renderIdleTitle(t("유휴", "idle"))
        } else if let b = block {
            let moodTier = resolveMood(hasActiveBlock: true, elapsedRatio: b.progress, warning: warning)
            let ctx = TitleContext(outputTokens: blockStats.outputTokens,
                                   totalTokens: blockStats.totalTokens,
                                   cost: blockStats.totalCost,
                                   remainingText: b.remaining > 0 ? formatTime(b.remaining) : nil,
                                   model: blockEntries.last?.model,
                                   moodTier: moodTier,
                                   moodPulsePhase: moodPulsePhase,
                                   todayTokens: gamificationTodayTokens,
                                   todayCost: gamificationTodayCost,
                                   cumulativeTokens: UsageStats(entries: cachedAll).totalTokens)
            renderTitle(parts: titlePartsWithBadge(ctx), warning: warning)
        }
    }

    // ── 1차 경로: Claude Code stats-cache.json (권위 비용·실제 5시간 블록) ──
    func buildMenu(fromCache stats: StatsCache) {
        updateStatusBarTitle(fromCache: stats)
        let menu = NSMenu()
        menu.autoenablesItems = false
        renderBlockMenu(makeBlockDisplayData(fromCache: stats), into: menu)
        appendFooter(menu)
        statusItem.menu = menu
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

        case .ready(let block, let model, let today, let allTime):
            if data.isEstimate {
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
                    addHeroLabel(menu, "  " + t("\(text) 남음", "\(text) remaining"), color: heroColor)
                case .alreadyReset:
                    addHeroLabel(menu, "  " + t("✅ 블록 리셋됨 — 새 블록 시작 가능", "✅ Block reset — a new block can start"), color: heroColor)
                case .none:
                    break
                }
                if b.showProgressBar {
                    addColoredLabel(menu, "  " + t("\(progressBar(b.progressRatio, width: 12)) \(Int(b.progressRatio * 100))% 경과", "\(progressBar(b.progressRatio, width: 12)) \(Int(b.progressRatio * 100))% elapsed"), color: heroColor)
                }

                addLabel(menu, "  " + t("\(formatCost(b.cost)) · \(formatTokens(b.outputTokens)) 출력 / \(formatTokens(b.totalTokens)) 전체 · \(b.messageCount)건",
                                        "\(formatCost(b.cost)) · \(formatTokens(b.outputTokens)) out / \(formatTokens(b.totalTokens)) total · \(b.messageCount) msgs"))

                var windowBurnParts: [String] = []
                if let windowText = b.windowText { windowBurnParts.append(windowText) }
                if let cph = b.burnRateText { windowBurnParts.append(t("소모율 \(cph)/시간", "burn \(cph)/hr")) }
                if !windowBurnParts.isEmpty {
                    addLabel(menu, "  " + windowBurnParts.joined(separator: " · "))
                }

                if let w = b.warning {
                    addLabel(menu, "  " + t("사용률: \(Int(w.ratio * 100))% (한도 대비)", "Usage: \(Int(w.ratio * 100))% (of limit)"))
                    if w.level != .none {
                        let warnColor: NSColor = (w.level == .crit) ? .systemRed : .systemOrange
                        addColoredLabel(menu, "  " + t("⚠️ 사용량 \(Int(w.ratio * 100))% — \(b.warningResetText) 남음", "⚠️ Usage \(Int(w.ratio * 100))% — \(b.warningResetText) remaining"), color: warnColor)
                    }
                }
                if let tier = b.moodTier {
                    let scopeWord = t(b.warning != nil ? "사용" : "경과", b.warning != nil ? "used" : "elapsed")
                    addLabel(menu, "  \(TitleSettings.moodGlyphTheme().glyph(for: tier)) " + t("기분: \(tier.label) (\(Int(b.moodRatio * 100))% \(scopeWord))", "Mood: \(tier.label) (\(Int(b.moodRatio * 100))% \(scopeWord))"))
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
                    for m in names { addLabel(menu, "  \(shortModelName(m))") }
                case .breakdown(let items, let unknownCount):
                    for item in items {
                        addLabel(menu, "  \(paddedModelColumn(item.model))  \(formatTokens(item.tokens))  \(formatCost(item.cost))")
                    }
                    if unknownCount > 0 {
                        addLabel(menu, "  " + t("⚠ 미상 모델 \(unknownCount)종 (추정 단가 적용)", "⚠ \(unknownCount) unknown model(s) (estimated pricing applied)"))
                    }
                }
                menu.addItem(.separator())
            }

            // ── Today Section ──
            addSectionHeader(menu, t("📅  오늘 (로컬 기준)", "📅  Today (Local Time)"))
            if today.hasUsage {
                addLabel(menu, "  " + t("전체 토큰: \(formatTokens(today.totalTokens))", "Total Tokens: \(formatTokens(today.totalTokens))"))
                addLabel(menu, "  " + t("예상 비용: \(formatCost(today.totalCost))", "Estimated Cost: \(formatCost(today.totalCost))"))
                if let mc = today.messageCount {
                    addLabel(menu, "  " + t("메시지 수: \(mc)건", "Messages: \(mc)"))
                }
                for mb in today.modelBreakdown ?? [] {
                    addLabel(menu, "  \(paddedModelColumn(mb.model))  \(formatTokens(mb.tokens))  \(formatCost(mb.cost))")
                }
            } else {
                addLabel(menu, "  " + t("사용 없음", "No usage"))
            }
            menu.addItem(.separator())

            // ── All-Time Section (캐시 경로는 stats.cumulative 없으면 통째로 생략) ──
            if let allTime = allTime {
                addSectionHeader(menu, t("📊  전체 누적", "📊  All-Time Total"))
                addLabel(menu, "  " + t("전체 토큰: \(formatTokens(allTime.totalTokens))", "Total Tokens: \(formatTokens(allTime.totalTokens))"))
                addLabel(menu, "  " + t("예상 비용: \(formatCost(allTime.totalCost))", "Estimated Cost: \(formatCost(allTime.totalCost))"))
                menu.addItem(.separator())
            }

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
    func appendFooter(_ menu: NSMenu) {
        let updateStr = formatTimeShort(lastUpdateTime)
        addLabel(menu, "  " + t("최종 업데이트: \(updateStr) (\(RefreshSettings.interval().label) 자동 갱신)",
                                "Last Updated: \(updateStr) (auto-refresh every \(RefreshSettings.interval().label))"))

        let refreshItem = NSMenuItem(title: "  🔄 " + t("지금 새로고침", "Refresh Now"), action: #selector(manualRefresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        // 재미 모드를 표시 항목 계열 서브메뉴보다 먼저 배치 — 가장 최근에 추가된 핵심 기능인데
        // 5개 서브메뉴 중 4번째에 묻혀 있으면 발견성이 떨어진다.
        let funModeItem = NSMenuItem(title: "  🎭 " + t("재미 모드", "Fun Mode"), action: nil, keyEquivalent: "")
        funModeItem.submenu = buildFunModeSubmenu()
        menu.addItem(funModeItem)

        // 무드 아이콘의 모양(테마)을 고르는 서브메뉴 — 무드 아이콘과 관련이 깊어 재미 모드 바로 다음에 배치.
        let moodGlyphThemeItem = NSMenuItem(title: "  🎨 " + t("무드 아이콘 모양", "Mood Icon Style"), action: nil, keyEquivalent: "")
        moodGlyphThemeItem.submenu = buildMoodGlyphThemeSubmenu()
        menu.addItem(moodGlyphThemeItem)

        let titleFieldsItem = NSMenuItem(title: "  ⌨ " + t("메뉴바 표시 항목", "Menu Bar Fields"), action: nil, keyEquivalent: "")
        titleFieldsItem.submenu = buildTitleFieldsSubmenu()
        menu.addItem(titleFieldsItem)

        let separatorItem = NSMenuItem(title: "  ⌇ " + t("표시 항목 구분자", "Field Separator"), action: nil, keyEquivalent: "")
        separatorItem.submenu = buildSeparatorSubmenu()
        menu.addItem(separatorItem)

        // "메뉴바 표시 항목"과 같은 ⌨ 글리프를 쓰면 두 서브메뉴가 구분되지 않아 🖼로 분리.
        let iconItem = NSMenuItem(title: "  🖼 " + t("메뉴바 아이콘", "Menu Bar Icon"), action: nil, keyEquivalent: "")
        iconItem.submenu = buildIconSubmenu()
        menu.addItem(iconItem)

        let refreshIntervalItem = NSMenuItem(title: "  ⏱ " + t("자동 갱신 주기", "Auto-Refresh Interval"), action: nil, keyEquivalent: "")
        refreshIntervalItem.submenu = buildRefreshIntervalSubmenu()
        menu.addItem(refreshIntervalItem)

        let languageItem = NSMenuItem(title: "  🌐 " + t("표시 언어", "Display Language"), action: nil, keyEquivalent: "")
        languageItem.submenu = buildLanguageSubmenu()
        menu.addItem(languageItem)

        menu.addItem(.separator())

        addLabel(menu, "  cc-menutor v\(APP_VERSION)")

        let quitItem = NSMenuItem(title: t("종료", "Quit"), action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
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

    // 라디오 스타일 서브메뉴 공통 빌더 — CaseIterable 값 하나를 "현재 선택"으로 표시하고
    // 나머지는 off로 둔다. @objc 셀렉터는 concrete 메서드여야 하므로(클로저 불가) 각 서브메뉴의
    // 개별 setX(_:) 핸들러는 그대로 두고, NSMenu 구성 루프만 이 헬퍼로 흡수한다.
    private func buildRadioSubmenu<T: CaseIterable & Equatable>(
        current: T, action: Selector, title: (T) -> String
    ) -> NSMenu where T.AllCases.Element == T {
        let sub = NSMenu()
        for value in T.allCases {
            let item = NSMenuItem(title: title(value), action: action, keyEquivalent: "")
            item.target = self
            item.state = (value == current) ? .on : .off
            item.representedObject = value
            sub.addItem(item)
        }
        return sub
    }

    // ── 표시 항목 구분자 서브메뉴(라디오 스타일 — 하나만 선택) ──
    func buildSeparatorSubmenu() -> NSMenu {
        buildRadioSubmenu(current: TitleSettings.separator(), action: #selector(setSeparator(_:))) { $0.label }
    }

    @objc func setSeparator(_ sender: NSMenuItem) {
        guard let sep = sender.representedObject as? TitleSeparator else { return }
        TitleSettings.setSeparator(sep)
        buildMenu()
    }

    // ── 메뉴바 아이콘 서브메뉴(라디오 스타일 — 하나만 선택, "표시 안 함" 포함) ──
    func buildIconSubmenu() -> NSMenu {
        buildRadioSubmenu(current: TitleSettings.icon(), action: #selector(setIcon(_:))) { $0.label }
    }

    @objc func setIcon(_ sender: NSMenuItem) {
        guard let icon = sender.representedObject as? TitleIcon else { return }
        TitleSettings.setIcon(icon)
        buildMenu()
    }

    // ── 무드 아이콘 모양 서브메뉴(라디오 스타일 — 하나만 선택). 무드 아이콘 토글이 꺼져 있어도
    // 다른 라디오 서브메뉴들과 동일하게 항상 노출한다 — 값을 미리 정해두면 나중에 토글을 켰을 때
    // 그대로 적용된다. ──
    func buildMoodGlyphThemeSubmenu() -> NSMenu {
        buildRadioSubmenu(current: TitleSettings.moodGlyphTheme(), action: #selector(setMoodGlyphTheme(_:))) { $0.label }
    }

    @objc func setMoodGlyphTheme(_ sender: NSMenuItem) {
        guard let theme = sender.representedObject as? MoodGlyphTheme else { return }
        TitleSettings.setMoodGlyphTheme(theme)
        buildMenu()
    }

    // ── 재미 모드 서브메뉴(체크리스트 — 3개 기능 독립 on/off, 라디오와 구조가 달라 별도 유지) ──
    func buildFunModeSubmenu() -> NSMenu {
        let sub = NSMenu()
        for feature in FunModeFeature.allCases {
            let item = NSMenuItem(title: feature.label, action: #selector(toggleFunModeFeature(_:)), keyEquivalent: "")
            item.target = self
            item.state = TitleSettings.isFunModeFeatureEnabled(feature) ? .on : .off
            item.representedObject = feature
            sub.addItem(item)
        }
        return sub
    }

    @objc func toggleFunModeFeature(_ sender: NSMenuItem) {
        guard let feature = sender.representedObject as? FunModeFeature else { return }
        TitleSettings.toggleFunModeFeature(feature)
        buildMenu()
    }

    // ── 자동 갱신 주기 서브메뉴(라디오 스타일 — 하나만 선택) ──
    func buildRefreshIntervalSubmenu() -> NSMenu {
        buildRadioSubmenu(current: RefreshSettings.interval(), action: #selector(setRefreshInterval(_:))) { $0.label }
    }

    @objc func setRefreshInterval(_ sender: NSMenuItem) {
        guard let interval = sender.representedObject as? RefreshInterval else { return }
        RefreshSettings.setInterval(interval)
        rescheduleTimer()
        buildMenu()
    }

    // ── 표시 언어 서브메뉴(라디오 스타일 — 하나만 선택) ──
    func buildLanguageSubmenu() -> NSMenu {
        buildRadioSubmenu(current: TitleSettings.languagePreference(), action: #selector(setLanguagePreference(_:))) { $0.label }
    }

    @objc func setLanguagePreference(_ sender: NSMenuItem) {
        guard let pref = sender.representedObject as? LanguagePreference else { return }
        TitleSettings.setLanguagePreference(pref)
        buildMenu()
    }

    // ── 폴백 경로: stats-cache.json 부재 시 JSONL 직접 파싱(추정 단가) ──
    func buildMenuFromEntries() {
        updateStatusBarTitleFromEntries()
        let menu = NSMenu()
        menu.autoenablesItems = false
        renderBlockMenu(makeBlockDisplayData(fromEntries: cachedAll, reader: reader), into: menu)
        appendFooter(menu)
        statusItem.menu = menu
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
    private func infoRowItem(_ title: String, font: NSFont, color: NSColor) -> NSMenuItem {
        let field = NSTextField(labelWithString: title)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byClipping
        field.sizeToFit()

        let leftInset: CGFloat = 14   // titleFieldRowView의 체크박스 x와 맞춰 다른 행과 정렬
        let rightPad: CGFloat = 6
        let rowHeight = max(18, field.frame.height + 2)
        let row = NSView(frame: NSRect(x: 0, y: 0,
                                        width: leftInset + field.frame.width + rightPad,
                                        height: rowHeight))
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

    func addLabel(_ menu: NSMenu, _ title: String) {
        menu.addItem(infoRowItem(title, font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular), color: .labelColor))
    }

    // 5시간 블록 섹션에서 가장 중요한 값(남은 시간/리셋 상태)을 다른 줄보다 크고 굵게 강조한다.
    func addHeroLabel(_ menu: NSMenu, _ title: String, color: NSColor) {
        menu.addItem(infoRowItem(title, font: NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .bold), color: color))
    }

    // addLabel과 폰트는 동일하되 색만 지정 — 진행률 바/경고 배너처럼 상태에 따라 색이 바뀌는 줄용.
    func addColoredLabel(_ menu: NSMenu, _ title: String, color: NSColor) {
        menu.addItem(infoRowItem(title, font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular), color: color))
    }

    // 경고 상태면 수치는 유지한 채 ⚠%를 덧붙이고 전체를 색(주황/빨강)으로 덮어써 항목별 색보다 우선시킨다.
    // (남은 시간은 메뉴 안에 표시되므로 타이틀에서는 생략)
    // 평상시엔 항목별 커스텀 색(TitlePart.color)을 적용하되, 항상 attributedTitle을 써서
    // 비포커스 화면(다중 디스플레이)에서 plain title이 자동으로 dim되는 것을 방지한다.
    func renderTitle(parts: [TitlePart], warning: UsageWarning?) {
        guard let button = statusItem.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        // 무드 아이콘 맥박 애니메이션의 강조 프레임 — 살짝 크고 굵게 해 "숨쉬는" 느낌을 준다.
        // 모노스페이스를 유지해 폭 흔들림은 최소화하되, 경고 배너 분기(아래)는 이미 색으로 강조되어
        // 있으므로 펄스를 얹지 않는다.
        let pulseFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
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
                .font: part.pulsing ? pulseFont : font,
                .foregroundColor: part.color.nsColor ?? NSColor.labelColor
            ]))
        }
        button.attributedTitle = result
    }

    func renderTitle(plain text: String, warning: UsageWarning?) {
        renderTitle(parts: [TitlePart(text: text, color: .defaultColor)], warning: warning)
    }

    @objc func manualRefresh() {
        refresh()
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

    // FunModeFeature: 케이스 목록/라벨 회귀 (activeRefreshFlash() 자체는 실제 Timer/앱 인스턴스
    // 상태에 의존해 이 순수 함수 테스트 스위트로는 검증하지 않음 — celebrationBadgeTimer와 동일한 관례)
    check(FunModeFeature.allCases.contains(.refreshFlash), "funMode: refreshFlash 케이스 포함")
    check(!FunModeFeature.refreshFlash.label.isEmpty, "funMode: refreshFlash 라벨 존재")

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
    check(buildTitleText(titleCtx) == "⌨ 12.3K $4.20", "title: outputTokens+cost 조합(기존 기본 포맷과 동일)")
    setEnabled([.remainingTime])
    check(buildTitleText(titleCtx) == "⌨", "title: 값 없는 필드만 선택 시 ⌨ 단독으로 축소")
    setEnabled([.model])
    check(buildTitleText(titleCtx) == "⌨ Sonnet 4.5", "title: 모델명만 선택")
    let todayCumulativeCtx = TitleContext(outputTokens: 0, totalTokens: 0, cost: 0, remainingText: nil, model: nil,
                                          todayTokens: 128_000, todayCost: 2.5, cumulativeTokens: 5_200_000)
    setEnabled([.todayTokens, .todayCost, .cumulativeTokens])
    check(buildTitleText(todayCumulativeCtx) == "⌨ 128.0K $2.50 5.20M",
          "title: 오늘 토큰+오늘 비용+누적 토큰 조합")
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
    check(buildTitleText(titleCtx) == "⌨ | Sonnet 4.5 | $4.20 | 12.3K",
          "title: 커스텀 순서(model→cost→outputTokens) + 구분자(|) 조합")
    TitleSettings.setSeparator(.none)
    check(buildTitleText(titleCtx) == "⌨Sonnet 4.5$4.2012.3K", "title: 구분자 없음 조합")
    TitleSettings.setIcon(.robot)
    TitleSettings.setSeparator(.space)
    check(buildTitleText(titleCtx) == "🤖 Sonnet 4.5 $4.20 12.3K", "title: 커스텀 아이콘(로봇) 조합")
    TitleSettings.setIcon(.none)
    check(buildTitleText(titleCtx) == "Sonnet 4.5 $4.20 12.3K", "title: 아이콘 없음 — 선행 구분자 없이 첫 필드부터 시작")
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
