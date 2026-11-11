import Foundation
import XCTest
@testable import UsageCore

final class UsageAggregatorTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }

    func testBucketsTodayRollingWindowAndSevenDays() {
        let now = LogTimestamp.parse("2026-11-11T07:00:00Z")! // 東京で 16:00
        let events = [
            UsageEvent(timestamp: LogTimestamp.parse("2026-11-11T06:00:00Z")!, model: "a", tokens: TokenCounts(input: 10)),
            UsageEvent(timestamp: LogTimestamp.parse("2026-11-11T01:00:00Z")!, model: "b", tokens: TokenCounts(output: 20)),
            // 東京では前日 23:30。今日には入らない。
            UsageEvent(timestamp: LogTimestamp.parse("2026-11-10T14:30:00Z")!, model: "a", tokens: TokenCounts(input: 5)),
            // 8 日前。7 日の範囲外。
            UsageEvent(timestamp: LogTimestamp.parse("2026-11-03T07:00:00Z")!, model: "a", tokens: TokenCounts(input: 1000)),
            // 未来（時計のずれ）を除く。
            UsageEvent(timestamp: LogTimestamp.parse("2026-11-11T09:00:00Z")!, model: "a", tokens: TokenCounts(input: 999)),
        ]
        let result = UsageAggregator.summarize(events, now: now, calendar: calendar)
        XCTAssertEqual(result.today.total, 30)
        XCTAssertEqual(result.rolling5Hours.total, 10)
        XCTAssertEqual(result.last7Days.count, 7)
        XCTAssertEqual(result.last7Days.last?.tokens.total, 30)
        XCTAssertEqual(result.last7Days.dropLast().last?.tokens.total, 5)
        XCTAssertEqual(result.last7Days.map(\.tokens.total).reduce(0, +), 35)
        XCTAssertEqual(result.todayByModel.map(\.model), ["b", "a"])
        XCTAssertEqual(result.lastActivity, LogTimestamp.parse("2026-11-11T06:00:00Z"))
    }
}

final class ClaudeBridgeSnapshotTests: XCTestCase {
    func testExtractsOnlyRateLimitsFromStatusLineInput() throws {
        let input = #"{"session_id":"s","transcript_path":"/secret/path.jsonl","model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1794390000},"seven_day":{"used_percentage":41,"resets_at":1794800000}}}"#
        let now = Date(timeIntervalSince1970: 1_794_380_000)
        let snapshot = try XCTUnwrap(ClaudeBridgeSnapshot.fromStatusLineInput(Data(input.utf8), now: now))
        XCTAssertEqual(snapshot.five_hour, .init(used_percentage: 23.5, resets_at: 1_794_390_000))
        XCTAssertEqual(snapshot.seven_day?.used_percentage, 41)
        XCTAssertNil(snapshot.spend_limit)
        let encoded = String(decoding: try snapshot.encoded(), as: UTF8.self)
        XCTAssertFalse(encoded.contains("secret"), "ステータスラインの入力のうち、数値以外はファイルに書かない")
        XCTAssertEqual(snapshot.rateLimitSnapshot.windows.map(\.label), ["5時間枠", "週間枠"])
    }

    func testReturnsNilWithoutRateLimits() {
        XCTAssertNil(ClaudeBridgeSnapshot.fromStatusLineInput(Data(#"{"model":{}}"#.utf8), now: Date()))
        XCTAssertNil(ClaudeBridgeSnapshot.fromStatusLineInput(Data(#"{"rate_limits":{}}"#.utf8), now: Date()))
        XCTAssertNil(ClaudeBridgeSnapshot.fromStatusLineInput(Data("garbage".utf8), now: Date()))
    }

    func testLoadRejectsOversizedSymlinkedAndInvalidFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("usagebar-snap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let valid = directory.appendingPathComponent("valid.json")
        let snapshot = ClaudeBridgeSnapshot(observed_at: 1, five_hour: .init(used_percentage: 5000, resets_at: 1e15), seven_day: nil, spend_limit: nil)
        try snapshot.encoded().write(to: valid)
        let loaded = try XCTUnwrap(ClaudeBridgeSnapshot.load(path: valid.path))
        XCTAssertEqual(loaded.five_hour?.used_percentage, 1000)
        XCTAssertNil(loaded.five_hour?.resets_at)

        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: valid)
        XCTAssertNil(ClaudeBridgeSnapshot.load(path: link.path))

        let big = directory.appendingPathComponent("big.json")
        try Data(repeating: 0x20, count: ClaudeBridgeSnapshot.maxFileBytes + 1).write(to: big)
        XCTAssertNil(ClaudeBridgeSnapshot.load(path: big.path))

        let wrongVersion = directory.appendingPathComponent("v2.json")
        try Data(#"{"version":2,"observed_at":1}"#.utf8).write(to: wrongVersion)
        XCTAssertNil(ClaudeBridgeSnapshot.load(path: wrongVersion.path))
    }
}

final class UsageEngineTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("usagebar-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("claude/p/sub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("codex/2026/11/11"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func engine() -> UsageEngine {
        UsageEngine(configuration: .init(
            claudeRoots: [root.appendingPathComponent("claude").path],
            codexRoots: [root.appendingPathComponent("codex").path],
            claudeBridgeSnapshotPath: root.appendingPathComponent("bridge/claude-rate-limits.json").path
        ))
    }

    private func claudeLine(id: String, at timestamp: String, output: Int) -> String {
        #"{"type":"assistant","timestamp":"\#(timestamp)","requestId":"r-\#(id)","message":{"id":"\#(id)","model":"claude-x","usage":{"input_tokens":1,"output_tokens":\#(output)}}}"#
    }

    func testDeduplicatesClaudeMessagesAcrossFilesAndPicksUpAppends() async throws {
        let now = Date()
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        let main = root.appendingPathComponent("claude/p/session.jsonl")
        let subagent = root.appendingPathComponent("claude/p/sub/agent.jsonl")
        // 同じ応答が content ブロックごとに複数行書かれ、さらに別ファイルにも複製されている。
        try Data((claudeLine(id: "m1", at: stamp, output: 9) + "\n" + claudeLine(id: "m1", at: stamp, output: 9) + "\n").utf8).write(to: main)
        try Data((claudeLine(id: "m1", at: stamp, output: 9) + "\n" + claudeLine(id: "m2", at: stamp, output: 90) + "\n").utf8).write(to: subagent)

        let engine = engine()
        await engine.scanAll(now: now)
        var summary = await engine.summary(now: now)
        XCTAssertEqual(summary.claude.rolling5Hours.total, 10 + 91)
        XCTAssertEqual(summary.claude.trackedFiles, 2)
        XCTAssertNil(summary.claude.rateLimits)

        let handle = try FileHandle(forWritingTo: main)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((claudeLine(id: "m3", at: stamp, output: 999) + "\n").utf8))
        try handle.close()
        await engine.process(changedPaths: [main.path], now: now)
        summary = await engine.summary(now: now)
        XCTAssertEqual(summary.claude.rolling5Hours.total, 10 + 91 + 1000)
    }

    func testReadsCodexUsageAndLatestRateLimitsAndCountsCompressedFiles() async throws {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        let older = formatter.string(from: now.addingTimeInterval(-600))
        let newer = formatter.string(from: now.addingTimeInterval(-60))
        func line(_ ts: String, total: Int, percent: Double) -> String {
            #"{"timestamp":"\#(ts)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(total),"output_tokens":0},"last_token_usage":{"input_tokens":\#(total),"output_tokens":0}},"rate_limits":{"primary":{"used_percent":\#(percent),"window_minutes":300,"resets_at":\#(Int(now.timeIntervalSince1970) + 3600)},"plan_type":"pro"}}}"#
        }
        try Data((line(older, total: 50, percent: 10) + "\n").utf8).write(to: root.appendingPathComponent("codex/2026/11/11/rollout-a.jsonl"))
        try Data((line(newer, total: 70, percent: 33) + "\n").utf8).write(to: root.appendingPathComponent("codex/2026/11/11/rollout-b.jsonl"))
        try Data([0x28, 0xB5, 0x2F, 0xFD]).write(to: root.appendingPathComponent("codex/2026/11/11/rollout-c.jsonl.zst"))

        let engine = engine()
        await engine.scanAll(now: now)
        let summary = await engine.summary(now: now)
        XCTAssertEqual(summary.codex.rolling5Hours.total, 120)
        XCTAssertEqual(summary.codex.rateLimits?.windows.first?.usedPercent, 33)
        XCTAssertEqual(summary.codex.rateLimits?.planType, "pro")
        XCTAssertEqual(summary.codex.notes.count, 1)
    }

    func testIgnoresChangedPathsOutsideRoots() async throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("usagebar-outside-\(UUID().uuidString).jsonl")
        try Data((claudeLine(id: "x", at: ISO8601DateFormatter().string(from: Date()), output: 5) + "\n").utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let engine = engine()
        await engine.process(changedPaths: [outside.path, root.appendingPathComponent("claude/../../etc/x.jsonl").path])
        let summary = await engine.summary()
        XCTAssertEqual(summary.claude.trackedFiles, 0)
    }
}
