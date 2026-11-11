import Foundation

/// ログファイルを読み、使用状況をまとめる。読み取り専用で、ファイルを書き換えることはない。
public actor UsageEngine {
    public struct Configuration: Sendable {
        public var claudeRoots: [String]
        public var codexRoots: [String]
        public var claudeBridgeSnapshotPath: String
        /// これより古いファイルとイベントは読まない。
        public var lookback: TimeInterval

        public init(claudeRoots: [String], codexRoots: [String], claudeBridgeSnapshotPath: String, lookback: TimeInterval = 8 * 24 * 3600) {
            // 走査で得るパスと FSEvents が知らせるパスを同じ表記にそろえる（/var と /private/var など）。
            self.claudeRoots = claudeRoots.map(UsageEngine.canonicalPath)
            self.codexRoots = codexRoots.map(UsageEngine.canonicalPath)
            self.claudeBridgeSnapshotPath = UsageEngine.canonicalPath(claudeBridgeSnapshotPath)
            self.lookback = lookback
        }

        public static var standard: Configuration {
            Configuration(
                claudeRoots: [UsagePaths.claudeProjects],
                codexRoots: [UsagePaths.codexSessions, UsagePaths.codexArchivedSessions],
                claudeBridgeSnapshotPath: UsagePaths.claudeBridgeSnapshot
            )
        }
    }

    private final class CodexFile {
        let cursor: JSONLFileCursor
        var state = CodexLogParser.FileState()
        var events: [UsageEvent] = []
        var latestLimits: RateLimitSnapshot?

        init(path: String) { cursor = JSONLFileCursor(path: path) }
    }

    private let config: Configuration
    private let claudeParser = ClaudeLogParser()
    private let codexParser = CodexLogParser()

    private var claudeCursors: [String: JSONLFileCursor] = [:]
    private var claudeKeyed: [String: UsageEvent] = [:]
    /// `message.id` の無いイベントは重複を判定できないため、ファイルごとに持ち、読み直すときに捨てる。
    private var claudeUnkeyed: [String: [UsageEvent]] = [:]
    private var claudeSnapshot: ClaudeBridgeSnapshot?

    private var codexFiles: [String: CodexFile] = [:]
    private var codexCompressedFiles = 0
    private var summarySequence = 0

    public init(configuration: Configuration = .standard) {
        self.config = configuration
    }

    // MARK: - 読み込み

    /// 監視対象のディレクトリを走査し、新しいファイルや追記分を読む。
    /// 前回から大きさが変わっていないファイルは開かない。
    public func scanAll(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-config.lookback)

        var seenClaude = Set<String>()
        for root in config.claudeRoots {
            for file in Self.enumerateFiles(root: root, modifiedAfter: cutoff) where file.path.hasSuffix(".jsonl") {
                seenClaude.insert(file.path)
                if let cursor = claudeCursors[file.path], cursor.offset == file.size { continue }
                readClaude(path: file.path, cutoff: cutoff)
            }
        }
        claudeCursors = claudeCursors.filter { seenClaude.contains($0.key) }
        claudeUnkeyed = claudeUnkeyed.filter { claudeCursors[$0.key] != nil }

        var seenCodex = Set<String>()
        var compressed = 0
        for root in config.codexRoots {
            for file in Self.enumerateFiles(root: root, modifiedAfter: cutoff) {
                if file.path.hasSuffix(".jsonl.zst") || file.path.hasSuffix(".zst") {
                    compressed += 1
                    continue
                }
                guard file.path.hasSuffix(".jsonl") else { continue }
                seenCodex.insert(file.path)
                if let existing = codexFiles[file.path], existing.cursor.offset == file.size { continue }
                readCodex(path: file.path, cutoff: cutoff)
            }
        }
        codexFiles = codexFiles.filter { seenCodex.contains($0.key) }
        codexCompressedFiles = compressed

        reloadClaudeSnapshot()
        prune(cutoff: cutoff)
    }

    /// ファイル監視で変更が通知されたパスだけを読む。
    public func process(changedPaths: [String], now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-config.lookback)
        for path in changedPaths.map(Self.canonicalPath) {
            if path == config.claudeBridgeSnapshotPath {
                reloadClaudeSnapshot()
            } else if path.hasSuffix(".jsonl") {
                if config.claudeRoots.contains(where: { Self.isInside(path, root: $0) }) {
                    readClaude(path: path, cutoff: cutoff)
                } else if config.codexRoots.contains(where: { Self.isInside(path, root: $0) }) {
                    readCodex(path: path, cutoff: cutoff)
                }
            }
        }
    }

    private func readClaude(path: String, cutoff: Date) {
        let cursor: JSONLFileCursor
        if let existing = claudeCursors[path] {
            cursor = existing
        } else {
            cursor = JSONLFileCursor(path: path)
            claudeCursors[path] = cursor
        }
        let outcome = cursor.readNewLines(onReset: {
            claudeUnkeyed[path] = nil
        }, onLine: { line in
            guard let record = claudeParser.parse(line: line), record.event.timestamp >= cutoff else { return }
            if let key = record.dedupeKey {
                if let existing = claudeKeyed[key], existing.tokens.total >= record.event.tokens.total { return }
                claudeKeyed[key] = record.event
            } else {
                claudeUnkeyed[path, default: []].append(record.event)
            }
        })
        if outcome == .unavailable {
            claudeCursors[path] = nil
            claudeUnkeyed[path] = nil
        }
    }

    private func readCodex(path: String, cutoff: Date) {
        let file: CodexFile
        if let existing = codexFiles[path] {
            file = existing
        } else {
            file = CodexFile(path: path)
            codexFiles[path] = file
        }
        let parser = codexParser
        let outcome = file.cursor.readNewLines(onReset: {
            file.state = CodexLogParser.FileState()
            file.events.removeAll()
            file.latestLimits = nil
        }, onLine: { line in
            for output in parser.parse(line: line, state: &file.state) {
                switch output {
                case .usage(let event):
                    if event.timestamp >= cutoff { file.events.append(event) }
                case .rateLimits(let snapshot):
                    if file.latestLimits.map({ snapshot.observedAt >= $0.observedAt }) ?? true {
                        file.latestLimits = snapshot
                    }
                }
            }
        })
        if outcome == .unavailable { codexFiles[path] = nil }
    }

    private func reloadClaudeSnapshot() {
        claudeSnapshot = ClaudeBridgeSnapshot.load(path: config.claudeBridgeSnapshotPath)
    }

    private func prune(cutoff: Date) {
        claudeKeyed = claudeKeyed.filter { $0.value.timestamp >= cutoff }
        claudeUnkeyed = claudeUnkeyed.compactMapValues { events in
            let kept = events.filter { $0.timestamp >= cutoff }
            return kept.isEmpty ? nil : kept
        }
        for file in codexFiles.values {
            file.events.removeAll { $0.timestamp < cutoff }
        }
    }

    // MARK: - 集計

    /// 集計結果に通し番号を付けて返す。並行して走った更新のうち、後に集計した方だけを画面に出すために使う。
    public func numberedSummary(now: Date = Date(), calendar: Calendar = .current) -> (sequence: Int, summary: UsageSummary) {
        summarySequence += 1
        return (summarySequence, summary(now: now, calendar: calendar))
    }

    public func summary(now: Date = Date(), calendar: Calendar = .current) -> UsageSummary {
        let claudeEvents = Array(claudeKeyed.values) + claudeUnkeyed.values.joined()
        let claude = UsageAggregator.summarize(claudeEvents, now: now, calendar: calendar)
        var claudeSummary = ProviderSummary(
            provider: .claude,
            rateLimits: claudeSnapshot?.rateLimitSnapshot,
            today: claude.today,
            rolling5Hours: claude.rolling5Hours,
            last7Days: claude.last7Days,
            todayByModel: claude.todayByModel,
            lastActivity: claude.lastActivity,
            trackedFiles: claudeCursors.count
        )
        if claudeSnapshot == nil {
            claudeSummary.notes.append(.claudeBridgeNotConfigured)
        }

        let codexEvents = codexFiles.values.flatMap(\.events)
        let codex = UsageAggregator.summarize(codexEvents, now: now, calendar: calendar)
        let latestCodexLimits = codexFiles.values
            .compactMap(\.latestLimits)
            .max { $0.observedAt < $1.observedAt }
        var codexSummary = ProviderSummary(
            provider: .codex,
            rateLimits: latestCodexLimits,
            today: codex.today,
            rolling5Hours: codex.rolling5Hours,
            last7Days: codex.last7Days,
            todayByModel: codex.todayByModel,
            lastActivity: codex.lastActivity,
            trackedFiles: codexFiles.count
        )
        if codexCompressedFiles > 0 {
            codexSummary.notes.append(.compressedLogsSkipped(codexCompressedFiles))
        }

        return UsageSummary(claude: claudeSummary, codex: codexSummary, generatedAt: now)
    }

    // MARK: - ファイル列挙

    struct FileEntry {
        var path: String
        var size: off_t
    }

    /// シンボリックリンクはたどらず、通常のファイルだけを返す。
    static func enumerateFiles(root: String, modifiedAfter cutoff: Date) -> [FileEntry] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root, isDirectory: true),
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var result: [FileEntry] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified >= cutoff else { continue }
            result.append(FileEntry(path: canonicalPath(url.path), size: off_t(values.fileSize ?? 0)))
        }
        return result
    }

    /// ディレクトリ部分のシンボリックリンクを解決したパス。ファイル自体のリンクはたどらない
    /// （リンクのファイルは JSONLFileCursor が開かない）。
    public static func canonicalPath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent().resolvingSymlinksInPath()
        return directory.appendingPathComponent(url.lastPathComponent).path
    }

    static func isInside(_ path: String, root: String) -> Bool {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) && !path.contains("/../")
    }
}
