import Foundation

/// Codex CLI のセッションログ（`~/.codex/sessions/**/rollout-*.jsonl`）から、
/// トークン数と利用上限（`rate_limits`）を取り出す。会話本文は読み捨てる。
public struct CodexLogParser {
    /// 1 ファイル分の読み取り状態。Codex のログは累計値を書くため、前回の累計を覚えておく。
    public struct FileState: Equatable {
        public var lastTotal: RawUsage?
        public var model: String?

        public init(lastTotal: RawUsage? = nil, model: String? = nil) {
            self.lastTotal = lastTotal
            self.model = model
        }
    }

    public enum Output: Equatable {
        case usage(UsageEvent)
        case rateLimits(RateLimitSnapshot)
    }

    /// Codex のログに書かれる値そのまま。`input_tokens` はキャッシュ分を含む。
    public struct RawUsage: Decodable, Equatable {
        public var input_tokens: Int64?
        public var cached_input_tokens: Int64?
        public var cache_write_input_tokens: Int64?
        public var output_tokens: Int64?
        public var total_tokens: Int64?

        var tokenCounts: TokenCounts {
            let input = TokenCounts.clamped(input_tokens)
            let cached = min(input, TokenCounts.clamped(cached_input_tokens))
            let written = min(input - cached, TokenCounts.clamped(cache_write_input_tokens))
            return TokenCounts(
                input: input - cached - written,
                cacheRead: cached,
                cacheWrite: written,
                output: TokenCounts.clamped(output_tokens)
            )
        }
    }

    private struct Line: Decodable {
        var timestamp: String?
        var type: String?
        var payload: Payload?
    }

    private struct Payload: Decodable {
        var type: String?
        var model: String?
        var info: Info?
        var rate_limits: RateLimits?
    }

    private struct Info: Decodable {
        var total_token_usage: RawUsage?
        var last_token_usage: RawUsage?
    }

    private struct RateLimits: Decodable {
        var primary: Window?
        var secondary: Window?
        var plan_type: String?
    }

    private struct Window: Decodable {
        var used_percent: Double?
        var window_minutes: Int?
        var resets_at: Double?
        var resets_in_seconds: Double?
    }

    private static let tokenCountNeedle = Array("\"token_count\"".utf8)
    private static let turnContextNeedle = Array("\"turn_context\"".utf8)

    private let decoder = JSONDecoder()

    public init() {}

    public func parse(line: Data, state: inout FileState) -> [Output] {
        let isTokenCount = line.containsBytes(Self.tokenCountNeedle)
        guard isTokenCount || line.containsBytes(Self.turnContextNeedle) else { return [] }
        guard let entry = try? decoder.decode(Line.self, from: line), let payload = entry.payload else { return [] }

        if entry.type == "turn_context" {
            if let model = payload.model, !model.isEmpty { state.model = model }
            return []
        }

        guard entry.type == "event_msg", payload.type == "token_count",
              let rawTimestamp = entry.timestamp,
              let timestamp = LogTimestamp.parse(rawTimestamp) else { return [] }

        var outputs: [Output] = []

        if let total = payload.info?.total_token_usage, total != state.lastTotal {
            // 累計が変わったときだけ、直近 1 回分（last_token_usage）を足す。
            // 同じ累計が二度書かれても数えず、再開したセッションが過去の累計を
            // 引き継いでいても、その累計を丸ごと足してしまうことはない。
            let isFirst = state.lastTotal == nil
            state.lastTotal = total
            let delta: TokenCounts
            if let last = payload.info?.last_token_usage {
                delta = last.tokenCounts
            } else if isFirst {
                delta = total.tokenCounts
            } else {
                delta = .zero
            }
            if delta.total > 0 {
                outputs.append(.usage(UsageEvent(timestamp: timestamp, model: state.model ?? "unknown", tokens: delta)))
            }
        }

        if let limits = payload.rate_limits {
            var windows: [RateWindow] = []
            for (id, window) in [("primary", limits.primary), ("secondary", limits.secondary)] {
                guard let window, let percent = window.used_percent, percent.isFinite else { continue }
                let resetsAt: Date?
                if let at = window.resets_at, EpochRange.isPlausible(at) {
                    resetsAt = Date(timeIntervalSince1970: at)
                } else if let seconds = window.resets_in_seconds, seconds.isFinite, seconds >= 0, seconds <= EpochRange.maxInterval {
                    resetsAt = timestamp.addingTimeInterval(seconds)
                } else {
                    resetsAt = nil
                }
                windows.append(RateWindow(
                    id: id,
                    usedPercent: min(max(percent, 0), 1000),
                    windowMinutes: window.window_minutes.flatMap { $0 > 0 ? $0 : nil },
                    resetsAt: resetsAt
                ))
            }
            if !windows.isEmpty {
                outputs.append(.rateLimits(RateLimitSnapshot(observedAt: timestamp, windows: windows, planType: limits.plan_type)))
            }
        }

        return outputs
    }
}
