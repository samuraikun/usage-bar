import Foundation

/// トークン数の内訳。プロバイダごとの数え方の違いはパーサー側で吸収し、
/// ここでは「キャッシュを使わなかった入力」「キャッシュ読み込み」「キャッシュ書き込み」「出力」に揃える。
public struct TokenCounts: Sendable, Equatable, Codable {
    public var input: Int64
    public var cacheRead: Int64
    public var cacheWrite: Int64
    public var output: Int64

    public init(input: Int64 = 0, cacheRead: Int64 = 0, cacheWrite: Int64 = 0, output: Int64 = 0) {
        self.input = input
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.output = output
    }

    public static let zero = TokenCounts()

    /// 1 回の応答で現実にあり得る上限。ログの値がこれを超えたら壊れた値とみなして抑える。
    public static let maxPerEvent: Int64 = 1_000_000_000_000

    /// ログ由来の値を 0 以上 `maxPerEvent` 以下に収める。
    public static func clamped(_ value: Int64?) -> Int64 {
        min(max(value ?? 0, 0), maxPerEvent)
    }

    public var total: Int64 {
        Self.saturatingSum(Self.saturatingSum(input, cacheRead), Self.saturatingSum(cacheWrite, output))
    }

    /// 足し算があふれたら Int64.max で止める（あふれるとプロセスが止まるため）。
    static func saturatingSum(_ a: Int64, _ b: Int64) -> Int64 {
        let (value, overflow) = a.addingReportingOverflow(b)
        if overflow { return b > 0 ? .max : .min }
        return value
    }

    public static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: saturatingSum(lhs.input, rhs.input),
            cacheRead: saturatingSum(lhs.cacheRead, rhs.cacheRead),
            cacheWrite: saturatingSum(lhs.cacheWrite, rhs.cacheWrite),
            output: saturatingSum(lhs.output, rhs.output)
        )
    }

    public static func += (lhs: inout TokenCounts, rhs: TokenCounts) {
        lhs = lhs + rhs
    }
}

/// 1 回の API 応答で使われたトークン数。
public struct UsageEvent: Sendable, Equatable {
    public var timestamp: Date
    public var model: String
    public var tokens: TokenCounts

    public init(timestamp: Date, model: String, tokens: TokenCounts) {
        self.timestamp = timestamp
        self.model = model
        self.tokens = tokens
    }
}

/// 利用上限の 1 つの枠（5 時間枠・週間枠など）。
public struct RateWindow: Sendable, Equatable, Identifiable {
    public var id: String
    public var usedPercent: Double
    public var windowMinutes: Int?
    public var resetsAt: Date?

    public init(id: String, usedPercent: Double, windowMinutes: Int?, resetsAt: Date?) {
        self.id = id
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }

    /// リセット時刻を過ぎた枠は、次に CLI を使って新しい値が届くまで 0% とみなす。
    public func isExpired(at now: Date) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }

    public func currentPercent(at now: Date) -> Double {
        isExpired(at: now) ? 0 : usedPercent
    }

    /// 枠の名前（「5時間枠」「Weekly」など）。
    public func label(in language: AppLanguage) -> String {
        let ja = language == .ja
        switch windowMinutes {
        case 300?: return ja ? "5時間枠" : "5-hour"
        case 10080?: return ja ? "週間枠" : "Weekly"
        case 1440?: return ja ? "1日枠" : "Daily"
        case let minutes? where minutes % 1440 == 0: return ja ? "\(minutes / 1440)日枠" : "\(minutes / 1440)-day"
        case let minutes? where minutes % 60 == 0: return ja ? "\(minutes / 60)時間枠" : "\(minutes / 60)-hour"
        case let minutes?: return ja ? "\(minutes)分枠" : "\(minutes)-minute"
        case nil:
            switch id {
            case "five_hour": return ja ? "5時間枠" : "5-hour"
            case "seven_day": return ja ? "週間枠" : "Weekly"
            case "spend_limit": return ja ? "利用額の上限" : "Spend limit"
            default: return id
            }
        }
    }
}

/// ある時点で観測した利用上限の状態。
public struct RateLimitSnapshot: Sendable, Equatable {
    public var observedAt: Date
    public var windows: [RateWindow]
    public var planType: String?

    public init(observedAt: Date, windows: [RateWindow], planType: String? = nil) {
        self.observedAt = observedAt
        self.windows = windows
        self.planType = planType
    }

    /// 最も上限に近い枠の使用率。メニューバーにはこの値を出す。
    public func highestPercent(at now: Date) -> Double? {
        windows.map { $0.currentPercent(at: now) }.max()
    }
}

public struct DailyTokens: Sendable, Equatable, Identifiable {
    public var day: Date
    public var tokens: TokenCounts
    public var id: Date { day }

    public init(day: Date, tokens: TokenCounts) {
        self.day = day
        self.tokens = tokens
    }
}

public struct ModelTokens: Sendable, Equatable, Identifiable {
    public var model: String
    public var tokens: TokenCounts
    public var id: String { model }

    public init(model: String, tokens: TokenCounts) {
        self.model = model
        self.tokens = tokens
    }
}

public enum Provider: String, Sendable, CaseIterable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
}

public struct ProviderSummary: Sendable, Equatable {
    public var provider: Provider
    public var rateLimits: RateLimitSnapshot?
    public var today: TokenCounts
    public var rolling5Hours: TokenCounts
    public var last7Days: [DailyTokens]
    public var todayByModel: [ModelTokens]
    public var lastActivity: Date?
    public var trackedFiles: Int
    /// 読めなかった・集計対象外にしたファイルの件数など、利用者に知らせる補足。
    public var notes: [ProviderNote]

    public init(
        provider: Provider,
        rateLimits: RateLimitSnapshot? = nil,
        today: TokenCounts = .zero,
        rolling5Hours: TokenCounts = .zero,
        last7Days: [DailyTokens] = [],
        todayByModel: [ModelTokens] = [],
        lastActivity: Date? = nil,
        trackedFiles: Int = 0,
        notes: [ProviderNote] = []
    ) {
        self.provider = provider
        self.rateLimits = rateLimits
        self.today = today
        self.rolling5Hours = rolling5Hours
        self.last7Days = last7Days
        self.todayByModel = todayByModel
        self.lastActivity = lastActivity
        self.trackedFiles = trackedFiles
        self.notes = notes
    }
}

public struct UsageSummary: Sendable, Equatable {
    public var claude: ProviderSummary
    public var codex: ProviderSummary
    public var generatedAt: Date

    public init(claude: ProviderSummary, codex: ProviderSummary, generatedAt: Date) {
        self.claude = claude
        self.codex = codex
        self.generatedAt = generatedAt
    }
}
