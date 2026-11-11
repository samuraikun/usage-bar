import Foundation
import XCTest
@testable import UsageCore

/// 壊れた値・細工された値を読んでも、止まらず妥当な値に収まることを確かめる。
final class HardeningTests: XCTestCase {
    func testHugeTokenValuesDoNotOverflow() throws {
        let line = #"{"type":"assistant","timestamp":"2026-11-11T07:00:00Z","message":{"id":"m","model":"x","usage":{"input_tokens":9223372036854775807,"output_tokens":9223372036854775807,"cache_read_input_tokens":9223372036854775807,"cache_creation_input_tokens":9223372036854775807}}}"#
        let record = try XCTUnwrap(ClaudeLogParser().parse(line: Data(line.utf8)))
        XCTAssertEqual(record.event.tokens.input, TokenCounts.maxPerEvent)
        var sum = TokenCounts.zero
        for _ in 0..<10_000_000 / 1_000_000 { sum += record.event.tokens }
        XCTAssertGreaterThan(sum.total, 0)

        let maxed = TokenCounts(input: .max, cacheRead: .max, cacheWrite: .max, output: .max)
        XCTAssertEqual(maxed.total, .max)
        XCTAssertEqual((maxed + maxed).input, .max)
    }

    func testCodexHugeTotalsAreClamped() throws {
        var state = CodexLogParser.FileState()
        let line = #"{"timestamp":"2026-11-11T07:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":9223372036854775807,"output_tokens":9223372036854775807},"last_token_usage":{"input_tokens":9223372036854775807,"cached_input_tokens":-1,"output_tokens":9223372036854775807}}}}"#
        guard case .usage(let event)? = CodexLogParser().parse(line: Data(line.utf8), state: &state).first else {
            return XCTFail("usage が無い")
        }
        XCTAssertEqual(event.tokens.input, TokenCounts.maxPerEvent)
        XCTAssertEqual(event.tokens.cacheRead, 0)
    }

    func testImplausibleResetTimesAreDropped() throws {
        var state = CodexLogParser.FileState()
        let line = #"{"timestamp":"2026-11-11T07:00:00Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":5,"window_minutes":300,"resets_at":1e300},"secondary":{"used_percent":5,"window_minutes":10080,"resets_in_seconds":1e300}}}}"#
        guard case .rateLimits(let snapshot)? = CodexLogParser().parse(line: Data(line.utf8), state: &state).first else {
            return XCTFail("rate_limits が無い")
        }
        XCTAssertEqual(snapshot.windows.map(\.resetsAt), [nil, nil])
    }

    func testSnapshotWithImplausibleObservedAtIsClamped() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("usagebar-hard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("s.json")
        try Data(#"{"version":1,"observed_at":1e300,"five_hour":{"used_percentage":1e300,"resets_at":-5}}"#.utf8).write(to: file)
        let snapshot = try XCTUnwrap(ClaudeBridgeSnapshot.load(path: file.path))
        XCTAssertEqual(snapshot.observed_at, EpochRange.min)
        XCTAssertEqual(snapshot.five_hour?.used_percentage, 1000)
        XCTAssertNil(snapshot.five_hour?.resets_at)
    }

    func testRejectsNonexistentDates() {
        XCTAssertNil(LogTimestamp.parse("2026-02-31T00:00:00Z"))
        XCTAssertNil(LogTimestamp.parse("2026-11-11T07:00:00.Z"))
        XCTAssertNil(LogTimestamp.parse("9999-01-01T00:00:00Z"))
        XCTAssertNotNil(LogTimestamp.parse("2028-02-29T00:00:00Z"))
    }
}

final class SnapshotMergeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_380_000)
    private func snap(_ five: Double?, reset: Double?, week: Double? = nil, weekReset: Double? = nil) -> ClaudeBridgeSnapshot {
        ClaudeBridgeSnapshot(
            observed_at: now.timeIntervalSince1970,
            five_hour: five.map { .init(used_percentage: $0, resets_at: reset) },
            seven_day: week.map { .init(used_percentage: $0, resets_at: weekReset) },
            spend_limit: nil
        )
    }

    func testStaleSessionDoesNotLowerSameWindow() {
        let previous = snap(40, reset: 1_794_390_000)
        // 別のセッションが同じ枠の古い（小さい）値を送ってきた。リセット時刻は秒の丸めで少しずれている。
        let merged = snap(25, reset: 1_794_390_002).merged(onto: previous, now: now)
        XCTAssertEqual(merged.five_hour?.used_percentage, 40)
        let grown = snap(55, reset: 1_794_390_000).merged(onto: previous, now: now)
        XCTAssertEqual(grown.five_hour?.used_percentage, 55)
    }

    func testNewerWindowWinsAndOlderWindowLoses() {
        let previous = snap(90, reset: 1_794_390_000)
        XCTAssertEqual(snap(3, reset: 1_794_408_000).merged(onto: previous, now: now).five_hour?.used_percentage, 3)
        let current = snap(3, reset: 1_794_408_000)
        XCTAssertEqual(snap(90, reset: 1_794_390_000).merged(onto: current, now: now).five_hour?.used_percentage, 3)
    }

    func testMissingWindowKeepsUnexpiredPreviousOnly() {
        let previous = snap(10, reset: 1_794_390_000, week: 30, weekReset: now.timeIntervalSince1970 - 10)
        let merged = snap(nil, reset: nil).merged(onto: previous, now: now)
        XCTAssertEqual(merged.five_hour?.used_percentage, 10)
        XCTAssertNil(merged.seven_day, "リセット時刻を過ぎた前回の値は残さない")
    }

    func testPreviousExpiredIsReplaced() {
        let previous = snap(90, reset: now.timeIntervalSince1970 - 1)
        XCTAssertEqual(snap(1, reset: now.timeIntervalSince1970 - 100).merged(onto: previous, now: now).five_hour?.used_percentage, 1)
    }
}

final class StatusLineCommandTests: XCTestCase {
    func testRecognisesOnlyWhatInstallWrites() {
        let path = "/Users/me/Applications/Usage Bar's.app/Contents/MacOS/usagebar-bridge"
        XCTAssertTrue(StatusLineCommand.isUsageBarBridge(StatusLineCommand.quoted(path)))
        XCTAssertTrue(StatusLineCommand.isUsageBarBridge("/opt/bin/usagebar-bridge"))

        XCTAssertFalse(StatusLineCommand.isUsageBarBridge("my.sh | usagebar-bridge"))
        XCTAssertFalse(StatusLineCommand.isUsageBarBridge("my.sh | /opt/bin/usagebar-bridge"))
        XCTAssertFalse(StatusLineCommand.isUsageBarBridge("'/a/b' | '/x/usagebar-bridge'"))
        XCTAssertFalse(StatusLineCommand.isUsageBarBridge("'/x/usagebar-bridge'; rm -rf ~ #'"))
        XCTAssertFalse(StatusLineCommand.isUsageBarBridge("usagebar-bridge"))
        XCTAssertFalse(StatusLineCommand.isUsageBarBridge("/x/usagebar-bridge-wrapper"))
    }

    func testQuotingSurvivesShellMetacharacters() {
        XCTAssertEqual(StatusLineCommand.quoted("/a/it's $(x)"), #"'/a/it'\''s $(x)'"#)
    }
}

final class ResetAndCalendarTests: XCTestCase {
    func testUnkeyedClaudeEventsAreNotDoubleCountedAfterReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usagebar-reset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("claude"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = UsageEngine(configuration: .init(
            claudeRoots: [root.appendingPathComponent("claude").path],
            codexRoots: [],
            claudeBridgeSnapshotPath: root.appendingPathComponent("none.json").path
        ))
        let stamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
        let line = #"{"type":"assistant","timestamp":"\#(stamp)","message":{"model":"x","usage":{"output_tokens":15}}}"# + "\n"
        let file = root.appendingPathComponent("claude/s.jsonl")
        try Data(line.utf8).write(to: file)
        await engine.scanAll()

        let replacement = root.appendingPathComponent("claude/s.tmp")
        try Data((line + line).utf8).write(to: replacement)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: replacement)
        await engine.process(changedPaths: [file.path])
        let total = await engine.summary().claude.rolling5Hours.total
        XCTAssertEqual(total, 30)
    }

    func testDaysAlignWhenMidnightIsSkipped() throws {
        // サンティアゴでは 2026-09-06 の 0 時が夏時間の開始で飛ぶ。
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Santiago"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 12)))
        let yesterday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 5, hour: 12)))
        let result = UsageAggregator.summarize(
            [UsageEvent(timestamp: yesterday, model: "a", tokens: TokenCounts(input: 7))],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(result.last7Days.map(\.tokens.total).reduce(0, +), 7)
        XCTAssertEqual(result.last7Days.dropLast().last?.tokens.total, 7)
    }
}
