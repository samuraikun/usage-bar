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
        XCTAssertEqual(snapshot.rateLimitSnapshot.windows.map { $0.label(in: .ja) }, ["5時間枠", "週間枠"])
        XCTAssertEqual(snapshot.rateLimitSnapshot.windows.map { $0.label(in: .en) }, ["5-hour", "Weekly"])
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
        XCTAssertEqual(summary.codex.notes, [.compressedLogsSkipped(1)])
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

final class ClaudeUsageCacheTests: XCTestCase {
    private func config(limits: String, fetchedAtMs: String = "1794380347152") -> Data {
        Data(#"{"oauthAccount":{"emailAddress":"secret@example.com"},"projects":{"/secret/project":{}},"cachedUsageUtilization":{"fetchedAtMs":\#(fetchedAtMs),"accountUuid":"secret-uuid","utilization":{"five_hour":{"utilization":2},"limits":\#(limits)}}}"#.utf8)
    }

    func testExtractsOnlyModelScopedWeeklyWindows() throws {
        let limits = #"""
        [{"kind":"session","group":"session","percent":2,"resets_at":"2026-11-11T11:50:00.080973+00:00","scope":null},
         {"kind":"weekly_all","group":"weekly","percent":32,"resets_at":"2026-11-14T21:00:00.080992+00:00","scope":null},
         {"kind":"weekly_scoped","group":"weekly","percent":5,"resets_at":"2026-11-14T21:00:00.081137+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}},
         {"kind":"weekly_scoped","percent":7,"resets_at":1794690000,"scope":{"model":null,"surface":{"display_name":"Cowork"}}},
         "unexpected",
         {"kind":"weekly_scoped","percent":"bad","scope":{"model":{"display_name":"Broken"}}}]
        """#
        let windows = ClaudeUsageCache.modelWindows(fromClaudeConfig: config(limits: limits))
        XCTAssertEqual(windows, [.init(display_name: "Fable", used_percentage: 5, resets_at: 1_794_690_000, observed_at: 1_794_380_347.152)])

        let snapshot = ClaudeBridgeSnapshot(observed_at: 1_794_380_400, five_hour: nil, seven_day: .init(used_percentage: 32, resets_at: 1_794_690_000), spend_limit: nil, model_scoped: windows)
        let encoded = String(decoding: try snapshot.encoded(), as: UTF8.self)
        XCTAssertFalse(encoded.contains("secret"), "~/.claude.json のうち、枠の名前と数値以外はファイルに書かない")
        let rows = snapshot.rateLimitSnapshot.windows
        XCTAssertEqual(rows.map { $0.label(in: .ja) }, ["週間枠", "週間枠（Fable）"])
        XCTAssertEqual(rows.map { $0.label(in: .en) }, ["Weekly", "Weekly (Fable)"])
        XCTAssertNil(rows[0].observedAt)
        XCTAssertEqual(rows[1].observedAt, Date(timeIntervalSince1970: 1_794_380_347.152))
    }

    func testAcceptsNumericResetAndCleansNames() {
        let limits = #"""
        [{"kind":"weekly_scoped","percent":5000,"resets_at":1794690000.9,"scope":{"model":{"display_name":"Fa\u001b[31mble <b>5.2</b> 日本語 and a very long tail of text"}}},
         {"kind":"weekly_scoped","percent":1,"resets_at":"not a date","scope":{"model":{"display_name":"Opus"}}},
         {"kind":"weekly_scoped","percent":9,"scope":{"model":{"display_name":"Opus"}}},
         {"kind":"weekly_scoped","percent":9,"scope":{"model":{"display_name":"日本"}}}]
        """#
        let windows = ClaudeUsageCache.modelWindows(fromClaudeConfig: config(limits: limits))
        XCTAssertEqual(windows.map(\.display_name), ["Fa31mble b5.2b  and a ve", "Opus"])
        XCTAssertEqual(windows[0].used_percentage, 1000)
        XCTAssertEqual(windows[0].resets_at, 1_794_690_000)
        XCTAssertNil(windows[1].resets_at)
        XCTAssertEqual(windows[1].used_percentage, 1, "同じ名前の枠は最初の 1 つだけ")
    }

    func testReturnsNothingForUnexpectedShapes() {
        XCTAssertEqual(ClaudeUsageCache.modelWindows(fromClaudeConfig: Data("garbage".utf8)), [])
        XCTAssertEqual(ClaudeUsageCache.modelWindows(fromClaudeConfig: Data(#"{"numStartups":3}"#.utf8)), [])
        XCTAssertEqual(ClaudeUsageCache.modelWindows(fromClaudeConfig: Data(#"{"cachedUsageUtilization":{"fetchedAtMs":1794380347152,"utilization":{"limits":"x"}}}"#.utf8)), [])
        let fable = #"[{"kind":"weekly_scoped","percent":5,"scope":{"model":{"display_name":"Fable"}}}]"#
        XCTAssertEqual(ClaudeUsageCache.modelWindows(fromClaudeConfig: config(limits: fable, fetchedAtMs: "1e30")), [])
        XCTAssertEqual(ClaudeUsageCache.modelWindows(fromClaudeConfig: config(limits: fable, fetchedAtMs: "\"x\"")), [])
        XCTAssertEqual(ClaudeUsageCache.loadModelWindows(path: "/nonexistent/.claude.json"), [])
    }

    func testLoadsFromFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usagebar-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(".claude.json")
        try config(limits: #"[{"kind":"weekly_scoped","percent":5,"resets_at":"2026-11-14T21:00:00+00:00","scope":{"model":{"display_name":"Fable"}}}]"#).write(to: file)
        XCTAssertEqual(ClaudeUsageCache.loadModelWindows(path: file.path).map(\.resets_at), [1_794_690_000])
    }
}

final class ModelWindowMergeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_380_000)
    private func snap(_ models: [ClaudeBridgeSnapshot.ModelWindow]?) -> ClaudeBridgeSnapshot {
        ClaudeBridgeSnapshot(observed_at: now.timeIntervalSince1970, five_hour: .init(used_percentage: 1, resets_at: 1_794_390_000), seven_day: nil, spend_limit: nil, model_scoped: models)
    }
    private func fable(_ percent: Double, reset: Double, observed: Double) -> ClaudeBridgeSnapshot.ModelWindow {
        .init(display_name: "Fable", used_percentage: percent, resets_at: reset, observed_at: observed)
    }

    func testKeepsNewerModelWindowWithItsObservedTime() {
        let previous = snap([fable(20, reset: 1_794_690_000, observed: 1_794_370_000)])
        // 古いキャッシュを読み直しただけなら、前回の値と取得時刻を残す。
        let stale = snap([fable(5, reset: 1_794_690_000, observed: 1_794_300_000)]).merged(onto: previous, now: now)
        XCTAssertEqual(stale.model_scoped, [fable(20, reset: 1_794_690_000, observed: 1_794_370_000)])
        let grown = snap([fable(30, reset: 1_794_690_000, observed: 1_794_379_000)]).merged(onto: previous, now: now)
        XCTAssertEqual(grown.model_scoped, [fable(30, reset: 1_794_690_000, observed: 1_794_379_000)])
        let nextWeek = snap([fable(1, reset: 1_795_294_800, observed: 1_794_379_000)]).merged(onto: previous, now: now)
        XCTAssertEqual(nextWeek.model_scoped?.first?.used_percentage, 1)
    }

    func testMissingModelWindowKeepsUnexpiredPreviousOnly() {
        let other = ClaudeBridgeSnapshot.ModelWindow(display_name: "Opus", used_percentage: 9, resets_at: now.timeIntervalSince1970 - 10, observed_at: 1_794_300_000)
        let previous = snap([fable(20, reset: 1_794_690_000, observed: 1_794_370_000), other])
        let merged = snap(nil).merged(onto: previous, now: now)
        XCTAssertEqual(merged.model_scoped?.map(\.display_name), ["Fable"], "リセット時刻を過ぎた前回の値は残さない")
        XCTAssertNil(snap(nil).merged(onto: snap(nil), now: now).model_scoped)
    }

    func testOldSnapshotFileWithoutModelWindowsStillLoads() throws {
        let old = #"{"five_hour":{"resets_at":1794464400,"used_percentage":24},"observed_at":1794461625.8,"seven_day":{"resets_at":1794690000,"used_percentage":43},"version":1}"#
        let decoded = try JSONDecoder().decode(ClaudeBridgeSnapshot.self, from: Data(old.utf8))
        XCTAssertNil(decoded.model_scoped)
        XCTAssertEqual(decoded.rateLimitSnapshot.windows.count, 2)
    }
}
