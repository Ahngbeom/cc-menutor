// ClaudeMonitor.swift
// Claude Code 5시간 블록 사용량 메뉴바 모니터
// Build:   swiftc -module-cache-path /tmp/swiftcache -o ClaudeMonitor ClaudeMonitor.swift -framework Cocoa
// Run:     ./ClaudeMonitor
// Test:    ./ClaudeMonitor --test
// Requires: macOS 12+, Claude Code CLI (https://claude.ai/code)

import Cocoa
import Foundation

let APP_VERSION = "1.2"

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

// 정밀 패턴이 매칭되면 matched=true, family/DEFAULT 폴백이면 matched=false.
func getPricing(for model: String) -> (pricing: ModelPricing, matched: Bool) {
    let lower = model.lowercased()
    for (pattern, pricing) in PRICING {
        if lower.contains(pattern) { return (pricing, true) }
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
    var s = model.lowercased()
    // 대괄호 접미사(예: [1m]) 제거
    s = s.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
    // 날짜 접미사(6자리 이상 연속 숫자) 제거 → 버전 숫자로 오인 방지
    s = s.replacingOccurrences(of: "[0-9]{6,}", with: "", options: .regularExpression)

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

    private let iso8601Full: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let iso8601Basic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

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
            return iso8601Full.date(from: s) ?? iso8601Basic.date(from: s)
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

// MARK: - Stats Cache (Claude Code's own aggregate, ~/.claude/stats-cache.json)
//
// Claude Code CLI가 직접 유지하는 권위 있는 사용량 집계. 이 앱이 손으로 재구현하던
// 5시간 블록·비용을 CLI가 이미 계산해 두므로 1차 소스로 사용한다.
// 스키마는 비공식이라 버전에 따라 바뀔 수 있음 → StatsBlock은 strict,
// 부차 필드(PeriodStats/ModelBreakdown)는 옵셔널로 느슨하게 두어 부분 드리프트에 견딘다.

private let isoCacheFull: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let isoCacheBasic: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()
func parseISO(_ s: String?) -> Date? {
    guard let s = s else { return nil }
    return isoCacheFull.date(from: s) ?? isoCacheBasic.date(from: s)
}

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
        guard let e = parseISO(endTime) else { return false }
        return now >= e
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

// MARK: - Menu Bar App

class ClaudeMonitorApp: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    let reader = UsageDataReader()
    let statsReader = StatsCacheReader()
    var lastUpdateTime = Date(timeIntervalSince1970: 0)
    var cachedAll: [UsageEntry] = []
    var cachedStats: StatsCache?
    private var isRefreshing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // Hide from Dock

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        statusItem.button?.title = "⌨ …"

        refresh()

        timer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // 읽기는 백그라운드 큐에서, UI 갱신은 메인 큐에서 수행.
    // 1차: stats-cache.json(권위 소스). 없으면 JSONL 전량 파싱 폴백.
    func refresh() {
        if isRefreshing { return }
        isRefreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let stats = self.statsReader.load()
            let entries: [UsageEntry] = (stats == nil) ? self.reader.readAll() : []
            DispatchQueue.main.async {
                self.cachedStats = stats
                self.cachedAll = entries
                self.lastUpdateTime = Date()
                self.buildMenu()
                self.isRefreshing = false
            }
        }
    }

    func buildMenu() {
        if let stats = cachedStats {
            buildMenu(fromCache: stats)
        } else {
            buildMenuFromEntries()
        }
    }

    // ── 1차 경로: Claude Code stats-cache.json (권위 비용·실제 5시간 블록) ──
    func buildMenu(fromCache stats: StatsCache) {
        let active = stats.activeBlock()
        let warning = active.flatMap { usageWarning(tokens: $0.totalTokens, cost: $0.costUSD) }
        let resetText: String = {
            guard let b = active else { return "" }
            if let rm = b.projection?.remainingMinutes { return formatTime(Double(rm) * 60) }
            if let e = parseISO(b.endTime) { return formatTime(max(0, e.timeIntervalSinceNow)) }
            return ""
        }()

        // --- Menu Bar Title ---
        if let b = active {
            renderTitle(normal: "⌨ \(formatTokens(b.tokenCounts.outputTokens)) \(formatCost(b.costUSD))",
                        warning: warning)
        } else {
            renderTitle(normal: "⌨ idle", warning: nil)
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

        // ── 5-Hour Block Section ──
        addSectionHeader(menu, "⏱  5시간 블록 현황")
        if let b = active {
            let start = parseISO(b.startTime)
            let end = parseISO(b.endTime)
            if let s = start, let e = end {
                addLabel(menu, "  \(formatTimeShort(s)) → \(formatTimeShort(e))")
            }
            addLabel(menu, "  출력 토큰: \(formatTokens(b.tokenCounts.outputTokens))")
            addLabel(menu, "  전체 토큰: \(formatTokens(b.totalTokens))")
            addLabel(menu, "  예상 비용: \(formatCost(b.costUSD))")
            addLabel(menu, "  메시지 수: \(b.entries)건")

            if let s = start, let e = end {
                let total = e.timeIntervalSince(s)
                let elapsed = max(0, min(total, Date().timeIntervalSince(s)))
                let ratio = total > 0 ? elapsed / total : 0
                addLabel(menu, "  \(progressBar(ratio, width: 12)) \(Int(ratio * 100))% 경과")
            }
            if let rm = b.projection?.remainingMinutes {
                addLabel(menu, "  리셋까지: \(formatTime(Double(rm) * 60)) 남음")
            } else if let e = end {
                let rem = e.timeIntervalSinceNow
                addLabel(menu, rem > 0 ? "  리셋까지: \(formatTime(rem)) 남음"
                                       : "  ✅ 블록 리셋됨 — 새 블록 시작 가능")
            }
            if let cph = b.burnRate?.costPerHour {
                addLabel(menu, "  소모율: \(formatCost(cph))/시간")
            }
            if let w = warning {
                addLabel(menu, "  사용률: \(Int(w.ratio * 100))% (한도 대비)")
                if w.level != .none {
                    addLabel(menu, "  ⚠️ 사용량 \(Int(w.ratio * 100))% — \(resetText) 남음")
                }
            }
            addLabel(menu, "  ⌨ 타이틀 = 블록 output 토큰 · 비용")
        } else {
            addLabel(menu, "  현재 활성 블록 없음")
            addLabel(menu, "  다음 메시지부터 새 블록이 시작됩니다.")
        }
        menu.addItem(.separator())

        // ── Models (current block; 이름만 — 블록 단위 분해는 캐시에 없음) ──
        if let b = active, !b.models.isEmpty {
            addSectionHeader(menu, "🤖  모델 (현재 블록)")
            for m in b.models {
                addLabel(menu, "  \(shortModelName(m))")
            }
            menu.addItem(.separator())
        }

        // ── Today Section (모델별 분해 포함) ──
        addSectionHeader(menu, "📅  오늘 (로컬 기준)")
        if let t = stats.todayPeriod() {
            addLabel(menu, "  전체 토큰: \(formatTokens(t.totalTokens ?? 0))")
            addLabel(menu, "  예상 비용: \(formatCost(t.totalCost ?? 0))")
            for mb in (t.modelBreakdowns ?? []).sorted(by: { ($0.cost ?? 0) > ($1.cost ?? 0) }) {
                let name = shortModelName(mb.modelName).padding(toLength: 12, withPad: " ", startingAt: 0)
                addLabel(menu, "  \(name)  \(formatTokens(mb.tokens))  \(formatCost(mb.cost ?? 0))")
            }
        } else {
            addLabel(menu, "  사용 없음")
        }
        menu.addItem(.separator())

        // ── Cumulative ──
        if let c = stats.cumulative {
            addSectionHeader(menu, "📊  전체 누적")
            addLabel(menu, "  전체 토큰: \(formatTokens(c.totalTokens ?? 0))")
            addLabel(menu, "  예상 비용: \(formatCost(c.totalCost ?? 0))")
            menu.addItem(.separator())
        }

        appendFooter(menu)
        statusItem.menu = menu
    }

    // ── 메뉴 하단 공통(최종 업데이트·새로고침·버전·종료) ──
    func appendFooter(_ menu: NSMenu) {
        let updateStr = formatTimeShort(lastUpdateTime)
        addLabel(menu, "  최종 업데이트: \(updateStr) (30초 자동 갱신)")

        let refreshItem = NSMenuItem(title: "  🔄 지금 새로고침", action: #selector(manualRefresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())

        addLabel(menu, "  Claude Monitor v\(APP_VERSION)")

        let quitItem = NSMenuItem(title: "종료", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // ── 폴백 경로: stats-cache.json 부재 시 JSONL 직접 파싱(추정 단가) ──
    func buildMenuFromEntries() {
        let block = FiveHourBlock.active(from: cachedAll)
        let blockEntries: [UsageEntry]
        if let block = block {
            blockEntries = cachedAll.filter { $0.timestamp >= block.start && $0.timestamp < block.end }
        } else {
            blockEntries = []
        }
        let blockStats = UsageStats(entries: blockEntries)

        let todayStart = Calendar.current.startOfDay(for: Date())
        let todayEntries = cachedAll.filter { $0.timestamp >= todayStart }
        let todayStats = UsageStats(entries: todayEntries)
        let allStats = UsageStats(entries: cachedAll)

        let noData = cachedAll.isEmpty && !FileManager.default.fileExists(
            atPath: reader.projectsDir.path)

        let warning = (block != nil) ? usageWarning(tokens: blockStats.totalTokens, cost: blockStats.totalCost) : nil
        let resetText = block.map { formatTime($0.remaining) } ?? ""

        // --- Menu Bar Title ---
        if noData {
            renderTitle(normal: "⌨ no data", warning: nil)
        } else if block == nil {
            renderTitle(normal: "⌨ idle", warning: nil)
        } else {
            renderTitle(normal: "⌨ \(formatTokens(blockStats.outputTokens)) \(formatCost(blockStats.totalCost))",
                        warning: warning)
        }

        // --- Build Menu ---
        let menu = NSMenu()
        menu.autoenablesItems = false

        if noData {
            addSectionHeader(menu, "⚠️  데이터 없음")
            addLabel(menu, "  Claude Code를 먼저 실행해 주세요.")
            addLabel(menu, "  경로: ~/.claude/projects/")
            menu.addItem(.separator())
        } else {
            // 1차 소스(stats-cache.json) 부재 → JSONL 추정 경로임을 사용자에게 명시.
            addSectionHeader(menu, "⚠ 추정 모드 — stats-cache.json 없음 (비용은 근사치)")
            menu.addItem(.separator())

            // ── 5-Hour Block Section ──
            addSectionHeader(menu, "⏱  5시간 블록 현황")

            if let block = block {
                let blockStartStr = formatTimeShort(block.start)
                let blockEndStr   = formatTimeShort(block.end)
                addLabel(menu, "  \(blockStartStr) → \(blockEndStr)")
                addLabel(menu, "  출력 토큰: \(formatTokens(blockStats.outputTokens))")
                addLabel(menu, "  전체 토큰: \(formatTokens(blockStats.totalTokens))")
                addLabel(menu, "  예상 비용: \(formatCost(blockStats.totalCost))")
                addLabel(menu, "  메시지 수: \(blockStats.count)건")

                let rem = block.remaining
                if rem > 0 {
                    let pct = Int(block.progress * 100)
                    let bar = progressBar(block.progress, width: 12)
                    addLabel(menu, "  \(bar) \(pct)% 경과")
                    addLabel(menu, "  리셋까지: \(formatTime(rem)) 남음")
                } else {
                    addLabel(menu, "  ✅ 블록 리셋됨 — 새 블록 시작 가능")
                }
                if let w = warning {
                    addLabel(menu, "  사용률: \(Int(w.ratio * 100))% (한도 대비)")
                    if w.level != .none {
                        addLabel(menu, "  ⚠️ 사용량 \(Int(w.ratio * 100))% — \(resetText) 남음")
                    }
                }
                addLabel(menu, "  ⌨ 타이틀 = 블록 output 토큰 · 추정 총비용")
            } else {
                addLabel(menu, "  현재 활성 블록 없음")
                addLabel(menu, "  다음 메시지부터 새 블록이 시작됩니다.")
            }

            menu.addItem(.separator())

            // ── Model Breakdown (within block) ──
            if !blockStats.modelBreakdown.isEmpty {
                addSectionHeader(menu, "🤖  모델별 (현재 블록)")
                for item in blockStats.modelBreakdown {
                    let line = "  \(item.model.padding(toLength: 12, withPad: " ", startingAt: 0))  \(formatTokens(item.tokens))  \(formatCost(item.cost))"
                    addLabel(menu, line)
                }
                if !blockStats.unknownModels.isEmpty {
                    addLabel(menu, "  ⚠ 미상 모델 \(blockStats.unknownModels.count)종 (추정 단가 적용)")
                }
                menu.addItem(.separator())
            }

            // ── Today Section ──
            addSectionHeader(menu, "📅  오늘 (로컬 기준)")
            if todayStats.count == 0 {
                addLabel(menu, "  사용 없음")
            } else {
                addLabel(menu, "  전체 토큰: \(formatTokens(todayStats.totalTokens))")
                addLabel(menu, "  예상 비용: \(formatCost(todayStats.totalCost))")
                addLabel(menu, "  메시지 수: \(todayStats.count)건")
            }

            menu.addItem(.separator())

            // ── All Time ──
            addSectionHeader(menu, "📊  전체 누적")
            addLabel(menu, "  전체 토큰: \(formatTokens(allStats.totalTokens))")
            addLabel(menu, "  예상 비용: \(formatCost(allStats.totalCost))")

            menu.addItem(.separator())
        }

        appendFooter(menu)
        statusItem.menu = menu
    }

    func addSectionHeader(_ menu: NSMenu, _ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        item.attributedTitle = NSAttributedString(string: title, attributes: attrs)
        menu.addItem(item)
    }

    func addLabel(_ menu: NSMenu, _ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        ]
        item.attributedTitle = NSAttributedString(string: title, attributes: attrs)
        menu.addItem(item)
    }

    // 경고 상태면 수치는 유지한 채 ⚠%를 덧붙이고 색(주황/빨강)만 입힌다.
    // (남은 시간은 메뉴 안에 표시되므로 타이틀에서는 생략) 평상시엔 플레인 title(메뉴바 자동 색).
    func renderTitle(normal: String, warning: UsageWarning?) {
        guard let button = statusItem.button else { return }
        if let w = warning, w.level != .none {
            let color: NSColor = (w.level == .crit) ? .systemRed : .systemOrange
            let text = "\(normal) ⚠\(Int(w.ratio * 100))%"
            button.attributedTitle = NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: color
            ])
        } else {
            button.title = normal   // 플레인 → 다크/라이트 자동 색
        }
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
    let inBlock = parseISO("2026-06-30T07:00:00.000Z")!
    if let sc = try? JSONDecoder().decode(StatsCache.self, from: Data(cacheJSON.utf8)) {
        check(sc.activeBlock(now: inBlock)?.costUSD == 84.77, "stats: activeBlock costUSD")
        check(sc.activeBlock(now: inBlock)?.tokenCounts.outputTokens == 594516, "stats: activeBlock outputTokens")
        check(sc.activeBlock(now: inBlock)?.projection?.remainingMinutes == 77, "stats: projection remainingMinutes")
        // isActive:true 이지만 endTime(10:00Z) 이후 시각 → stale 캐시로 보고 배제
        check(sc.activeBlock(now: parseISO("2026-06-30T11:00:00.000Z")!) == nil, "stats: 만료된 활성 블록 배제(stale)")
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

    if failures == 0 {
        print("All tests passed. ✅")
        exit(0)
    } else {
        print("\(failures) test(s) failed. ❌")
        exit(1)
    }
}

// MARK: - Entry Point

if CommandLine.arguments.contains("--test") {
    runSelfTests()
}

let app = NSApplication.shared
let delegate = ClaudeMonitorApp()
app.delegate = delegate
app.run()
