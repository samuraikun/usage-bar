import Foundation

/// Claude Code の会話ログ（`~/.claude/projects/**/*.jsonl`）の 1 行から、トークン数だけを取り出す。
/// 会話本文やツールの入出力は型に含めず、読み捨てる。
public struct ClaudeLogParser {
    public struct Record: Equatable {
        /// 同じ応答がログに複数回書かれるため、`message.id` と `requestId` で重複を判定する。
        public var dedupeKey: String?
        public var event: UsageEvent
    }

    private struct Line: Decodable {
        var type: String?
        var timestamp: String?
        var requestId: String?
        var message: Message?
    }

    private struct Message: Decodable {
        var id: String?
        var model: String?
        var usage: Usage?
    }

    private struct Usage: Decodable {
        var input_tokens: Int64?
        var output_tokens: Int64?
        var cache_creation_input_tokens: Int64?
        var cache_read_input_tokens: Int64?
    }

    private static let usageNeedle = Array("\"usage\"".utf8)
    private static let assistantNeedle = Array("\"assistant\"".utf8)

    private let decoder = JSONDecoder()

    public init() {}

    public func parse(line: Data) -> Record? {
        guard line.containsBytes(Self.usageNeedle), line.containsBytes(Self.assistantNeedle) else { return nil }
        guard let entry = try? decoder.decode(Line.self, from: line),
              entry.type == "assistant",
              let message = entry.message,
              let usage = message.usage,
              let rawTimestamp = entry.timestamp,
              let timestamp = LogTimestamp.parse(rawTimestamp) else { return nil }

        let model = message.model ?? "unknown"
        // API を呼ばずに Claude Code が差し込んだメッセージ。トークンを消費していない。
        guard model != "<synthetic>" else { return nil }

        let tokens = TokenCounts(
            input: TokenCounts.clamped(usage.input_tokens),
            cacheRead: TokenCounts.clamped(usage.cache_read_input_tokens),
            cacheWrite: TokenCounts.clamped(usage.cache_creation_input_tokens),
            output: TokenCounts.clamped(usage.output_tokens)
        )
        guard tokens.total > 0 else { return nil }

        let key = message.id.map { "\($0):\(entry.requestId ?? "")" }
        return Record(dedupeKey: key, event: UsageEvent(timestamp: timestamp, model: model, tokens: tokens))
    }
}
