import Foundation
import XCTest
@testable import UsageCore

final class JSONLFileCursorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("usagebar-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func lines(_ cursor: JSONLFileCursor, resets: inout Int) -> [String] {
        var result: [String] = []
        cursor.readNewLines(onReset: { resets += 1 }, onLine: { result.append(String(decoding: $0, as: UTF8.self)) })
        return result
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    func testReadsOnlyCompleteLinesAndContinuesFromOffset() throws {
        let url = directory.appendingPathComponent("a.jsonl")
        try Data("one\ntwo\nthr".utf8).write(to: url)
        let cursor = JSONLFileCursor(path: url.path)
        var resets = 0

        XCTAssertEqual(lines(cursor, resets: &resets), ["one", "two"])
        try append("ee\nfour\n", to: url)
        XCTAssertEqual(lines(cursor, resets: &resets), ["three", "four"])
        XCTAssertEqual(lines(cursor, resets: &resets), [])
        XCTAssertEqual(resets, 0)
    }

    func testRereadsWhenFileIsReplacedOrTruncated() throws {
        let url = directory.appendingPathComponent("b.jsonl")
        try Data("old1\nold2\n".utf8).write(to: url)
        let cursor = JSONLFileCursor(path: url.path)
        var resets = 0
        XCTAssertEqual(lines(cursor, resets: &resets), ["old1", "old2"])

        // 別のファイルに置き換える（inode が変わる）。
        let replacement = directory.appendingPathComponent("b.tmp")
        try Data("new1\n".utf8).write(to: replacement)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: replacement)
        XCTAssertEqual(lines(cursor, resets: &resets), ["new1"])
        XCTAssertEqual(resets, 1)

        // 同じファイルを短くする。
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.close()
        try append("x\n", to: url)
        XCTAssertEqual(lines(cursor, resets: &resets), ["x"])
        XCTAssertEqual(resets, 2)
    }

    func testSkipsOversizedLines() throws {
        let url = directory.appendingPathComponent("c.jsonl")
        let huge = String(repeating: "a", count: 100)
        try Data("ok\n\(huge)\nafter\n".utf8).write(to: url)
        let cursor = JSONLFileCursor(path: url.path, maxLineBytes: 10)
        var resets = 0
        XCTAssertEqual(lines(cursor, resets: &resets), ["ok", "after"])
    }

    func testSkipsOversizedLineSpanningReads() throws {
        let url = directory.appendingPathComponent("d.jsonl")
        try Data("ok\naaaaaaaaaaaaaaaaaaaa".utf8).write(to: url)
        let cursor = JSONLFileCursor(path: url.path, maxLineBytes: 10)
        var resets = 0
        XCTAssertEqual(lines(cursor, resets: &resets), ["ok"])
        try append("aaaa\nnext\n", to: url)
        XCTAssertEqual(lines(cursor, resets: &resets), ["next"])
    }

    func testDoesNotFollowSymlinks() throws {
        let target = directory.appendingPathComponent("target.jsonl")
        try Data("secret\n".utf8).write(to: target)
        let link = directory.appendingPathComponent("link.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let cursor = JSONLFileCursor(path: link.path)
        var received: [Data] = []
        XCTAssertEqual(cursor.readNewLines(onLine: { received.append($0) }), .unavailable)
        XCTAssertTrue(received.isEmpty)
    }
}
