import Foundation
import XCTest
@testable import UsageCore

final class ClaudeLogParserTests: XCTestCase {
    private let parser = ClaudeLogParser()

    func testParsesAssistantUsage() throws {
        let line = #"{"type":"assistant","timestamp":"2026-11-11T07:02:48.792Z","requestId":"req_1","message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"text","text":"秘密の本文"}],"usage":{"input_tokens":2,"cache_creation_input_tokens":3678,"cache_read_input_tokens":218888,"output_tokens":231}}}"#
        let record = try XCTUnwrap(parser.parse(line: Data(line.utf8)))
        XCTAssertEqual(record.dedupeKey, "msg_1:req_1")
        XCTAssertEqual(record.event.model, "claude-opus-5-5")
        XCTAssertEqual(record.event.tokens, TokenCounts(input: 2, cacheRead: 218888, cacheWrite: 3678, output: 231))
        XCTAssertEqual(record.event.timestamp.timeIntervalSince1970, 1_794_380_568.792, accuracy: 0.001)
    }

    func testIgnoresUserLinesThatMentionUsage() {
        let line = #"{"type":"user","timestamp":"2026-11-11T07:02:48.792Z","message":{"role":"user","content":"\"usage\" と \"assistant\" という文字列"}}"#
        XCTAssertNil(parser.parse(line: Data(line.utf8)))
    }

    func testIgnoresSyntheticAndZeroUsage() {
        let synthetic = #"{"type":"assistant","timestamp":"2026-11-11T07:02:48Z","message":{"id":"m","model":"<synthetic>","usage":{"input_tokens":5,"output_tokens":5}}}"#
        let zero = #"{"type":"assistant","timestamp":"2026-11-11T07:02:48Z","message":{"id":"m","model":"x","usage":{"input_tokens":0,"output_tokens":0}}}"#
        XCTAssertNil(parser.parse(line: Data(synthetic.utf8)))
        XCTAssertNil(parser.parse(line: Data(zero.utf8)))
    }

    func testRejectsMalformedAndNegativeValues() throws {
        XCTAssertNil(parser.parse(line: Data(#"{"type":"assistant","usage" "#.utf8)))
        let negative = #"{"type":"assistant","timestamp":"2026-11-11T07:02:48Z","message":{"model":"x","usage":{"input_tokens":-100,"output_tokens":7}}}"#
        let record = try XCTUnwrap(parser.parse(line: Data(negative.utf8)))
        XCTAssertEqual(record.event.tokens, TokenCounts(output: 7))
        XCTAssertNil(record.dedupeKey)
    }
}

final class CodexLogParserTests: XCTestCase {
    private let parser = CodexLogParser()

    private func tokenCount(_ timestamp: String, total: Int, last: Int, cached: Int = 0, output: Int = 0, rateLimits: String = "null") -> Data {
        Data(#"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(total),"cached_input_tokens":0,"output_tokens":0,"total_tokens":\#(total)},"last_token_usage":{"input_tokens":\#(last),"cached_input_tokens":\#(cached),"cache_write_input_tokens":0,"output_tokens":\#(output),"total_tokens":\#(last + output)}},"rate_limits":\#(rateLimits)}}"#.utf8)
    }

    func testCountsLastUsageOnlyWhenTotalChanges() {
        var state = CodexLogParser.FileState()
        let first = parser.parse(line: tokenCount("2026-11-11T07:00:00Z", total: 100, last: 100, cached: 40, output: 5), state: &state)
        XCTAssertEqual(first, [.usage(UsageEvent(
            timestamp: LogTimestamp.parse("2026-11-11T07:00:00Z")!,
            model: "unknown",
            tokens: TokenCounts(input: 60, cacheRead: 40, cacheWrite: 0, output: 5)
        ))])

        // 同じ累計がもう一度書かれても数えない。
        let duplicate = parser.parse(line: tokenCount("2026-11-11T07:00:01Z", total: 100, last: 100, cached: 40, output: 5), state: &state)
        XCTAssertEqual(duplicate, [])

        let second = parser.parse(line: tokenCount("2026-11-11T07:01:00Z", total: 130, last: 30), state: &state)
        XCTAssertEqual(second.count, 1)
    }

    func testResumedSessionDoesNotCountInheritedTotal() {
        var state = CodexLogParser.FileState()
        // 再開したセッションの最初のイベントは、過去の累計（100万）を引き継いでいる。
        let outputs = parser.parse(line: tokenCount("2026-11-11T07:00:00Z", total: 1_000_000, last: 500), state: &state)
        guard case .usage(let event)? = outputs.first else { return XCTFail("usage が無い") }
        XCTAssertEqual(event.tokens.total, 500)
    }

    func testUsesModelFromTurnContext() {
        var state = CodexLogParser.FileState()
        _ = parser.parse(line: Data(#"{"timestamp":"2026-11-11T07:00:00Z","type":"turn_context","payload":{"model":"gpt-6.1-sol","cwd":"/tmp"}}"#.utf8), state: &state)
        let outputs = parser.parse(line: tokenCount("2026-11-11T07:00:01Z", total: 10, last: 10), state: &state)
        guard case .usage(let event)? = outputs.first else { return XCTFail("usage が無い") }
        XCTAssertEqual(event.model, "gpt-6.1-sol")
    }

    func testParsesRateLimitsWithAbsoluteAndRelativeReset() throws {
        var state = CodexLogParser.FileState()
        let limits = #"{"limit_id":"codex","primary":{"used_percent":11.0,"window_minutes":10080,"resets_at":1794400000},"secondary":{"used_percent":42.5,"window_minutes":300,"resets_in_seconds":600},"plan_type":"plus"}"#
        let outputs = parser.parse(line: tokenCount("2026-11-11T07:00:00Z", total: 10, last: 10, rateLimits: limits), state: &state)
        let snapshot = try XCTUnwrap(outputs.compactMap { output -> RateLimitSnapshot? in
            if case .rateLimits(let s) = output { return s }
            return nil
        }.first)
        XCTAssertEqual(snapshot.planType, "plus")
        XCTAssertEqual(snapshot.windows.map { $0.label(in: .ja) }, ["週間枠", "5時間枠"])
        XCTAssertEqual(snapshot.windows.map { $0.label(in: .en) }, ["Weekly", "5-hour"])
        XCTAssertEqual(snapshot.windows[0].resetsAt, Date(timeIntervalSince1970: 1_794_400_000))
        XCTAssertEqual(snapshot.windows[1].resetsAt, LogTimestamp.parse("2026-11-11T07:10:00Z"))
        XCTAssertEqual(snapshot.highestPercent(at: LogTimestamp.parse("2026-11-11T07:05:00Z")!), 42.5)
        // 5 時間枠のリセット時刻を過ぎたら、その枠は 0% として扱う。
        XCTAssertEqual(snapshot.highestPercent(at: LogTimestamp.parse("2026-11-11T07:15:00Z")!), 11.0)
    }

    func testRejectsNonFiniteOrOutOfRangePercent() throws {
        var state = CodexLogParser.FileState()
        let limits = #"{"primary":{"used_percent":-5,"window_minutes":300},"secondary":{"used_percent":99999,"window_minutes":0}}"#
        let outputs = parser.parse(line: tokenCount("2026-11-11T07:00:00Z", total: 10, last: 10, rateLimits: limits), state: &state)
        let snapshot = try XCTUnwrap(outputs.compactMap { output -> RateLimitSnapshot? in
            if case .rateLimits(let s) = output { return s }
            return nil
        }.first)
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [0, 1000])
        XCTAssertNil(snapshot.windows[1].windowMinutes)
    }

    func testIgnoresMessagesThatOnlyMentionTokenCount() {
        var state = CodexLogParser.FileState()
        let line = #"{"timestamp":"2026-11-11T07:00:00Z","type":"response_item","payload":{"type":"message","content":"\"token_count\" を調べる"}}"#
        XCTAssertEqual(parser.parse(line: Data(line.utf8), state: &state), [])
    }
}

final class LogTimestampTests: XCTestCase {
    func testParsesVariants() {
        XCTAssertEqual(LogTimestamp.parse("2026-11-11T07:02:10Z")?.timeIntervalSince1970, 1_794_380_530)
        XCTAssertEqual(LogTimestamp.parse("2026-11-11T07:02:10.5Z")!.timeIntervalSince1970, 1_794_380_530.5, accuracy: 0.0001)
        XCTAssertEqual(LogTimestamp.parse("2026-11-11T16:02:10+09:00")?.timeIntervalSince1970, 1_794_380_530)
        XCTAssertNil(LogTimestamp.parse("2026-13-11T07:02:10Z"))
        XCTAssertNil(LogTimestamp.parse("not a date"))
    }
}
