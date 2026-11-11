import AppKit
import Combine
import OSLog
import ServiceManagement
import UsageCore

/// 画面に出す状態を持つ。ログの読み込みは `UsageEngine`（別スレッドで動く actor）に任せる。
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var summary: UsageSummary?
    @Published private(set) var now = Date()
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// ログイン時に起動の設定に失敗したときの、macOS が返した理由。
    @Published private(set) var launchAtLoginError: String?
    @Published var showPercentInMenuBar: Bool {
        didSet { UserDefaults.standard.set(showPercentInMenuBar, forKey: Self.showPercentKey) }
    }
    @Published var languagePreference: LanguagePreference {
        didSet { UserDefaults.standard.set(languagePreference.rawValue, forKey: Self.languageKey) }
    }
    /// Mac の言語設定が変わったときに描き直すための値。
    @Published private var systemLanguage = AppLanguage.fromSystem()

    /// いま画面に使う言語。
    var language: AppLanguage {
        languagePreference == .system ? systemLanguage : languagePreference.resolved()
    }

    private static let showPercentKey = "showPercentInMenuBar"
    private static let languageKey = "languagePreference"
    private static let logger = Logger(subsystem: "local.usagebar", category: "store")
    /// 表示中の「あと何分」を進める間隔。
    private static let tickInterval: TimeInterval = 30
    /// FSEvents の取りこぼしに備えて、ディレクトリ全体を見直す間隔。
    private static let fullScanInterval: TimeInterval = 300

    private let engine = UsageEngine()
    private var watcher: FileWatcher?
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var localeObserver: NSObjectProtocol?
    private var lastFullScan = Date.distantPast
    private var appliedSequence = 0

    /// 画面の確認用。ファイル監視もタイマーも動かさず、渡した集計結果だけを表示する。
    init(fixedSummary: UsageSummary, now: Date, language: AppLanguage) {
        showPercentInMenuBar = true
        languagePreference = language == .ja ? .ja : .en
        summary = fixedSummary
        self.now = now
    }

    init() {
        showPercentInMenuBar = UserDefaults.standard.object(forKey: Self.showPercentKey) as? Bool ?? true
        languagePreference = UserDefaults.standard.string(forKey: Self.languageKey)
            .flatMap(LanguagePreference.init(rawValue:)) ?? .system

        watcher = FileWatcher { [weak self] paths, needsFullScan in
            MainActor.assumeIsolated {
                self?.handleFileEvents(paths: paths, needsFullScan: needsFullScan)
            }
        }
        restartWatcherIfNeeded()
        scheduleFullScan()

        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNow() }
        }
        localeObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemLanguage = AppLanguage.fromSystem() }
        }
    }

    // MARK: - 表示用の値

    var claudeBridgeExecutablePath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/usagebar-bridge").path
    }

    func menuBarPercent(for provider: Provider) -> Double? {
        guard let summary else { return nil }
        let providerSummary = provider == .claude ? summary.claude : summary.codex
        return providerSummary.rateLimits?.highestPercent(at: now)
    }

    // MARK: - 操作

    func refreshNow() {
        now = Date()
        restartWatcherIfNeeded()
        scheduleFullScan()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - 内部

    private func tick() {
        now = Date()
        let watcherRestarted = restartWatcherIfNeeded()
        if watcherRestarted || now.timeIntervalSince(lastFullScan) >= Self.fullScanInterval {
            scheduleFullScan()
        } else {
            let engine = engine
            Task { await publish(from: engine) }
        }
    }

    private func handleFileEvents(paths: [String], needsFullScan: Bool) {
        if needsFullScan {
            scheduleFullScan()
            return
        }
        let engine = engine
        Task {
            await engine.process(changedPaths: paths)
            await publish(from: engine)
        }
    }

    private func scheduleFullScan() {
        lastFullScan = Date()
        let engine = engine
        Task {
            await engine.scanAll()
            await publish(from: engine)
        }
    }

    private func publish(from engine: UsageEngine) async {
        let current = Date()
        let (sequence, latest) = await engine.numberedSummary(now: current)
        guard sequence > appliedSequence else { return }
        appliedSequence = sequence
        now = current
        guard !Self.sameContent(latest, summary) else { return }
        let previous = summary
        summary = latest
        if previous?.claude.rateLimits != latest.claude.rateLimits || previous?.codex.rateLimits != latest.codex.rateLimits {
            // 使用率の数値だけを、この Mac の unified logging に残す（`log show --predicate 'subsystem == "local.usagebar"'`）。
            let claude = latest.claude.rateLimits?.highestPercent(at: current).map { String(format: "%.0f", $0) } ?? "-"
            let codex = latest.codex.rateLimits?.highestPercent(at: current).map { String(format: "%.0f", $0) } ?? "-"
            Self.logger.notice("rate limits updated claude=\(claude, privacy: .public)% codex=\(codex, privacy: .public)%")
        }
    }

    /// 集計時刻だけが違う結果は、画面を描き直さない。
    private static func sameContent(_ a: UsageSummary, _ b: UsageSummary?) -> Bool {
        guard var b else { return false }
        b.generatedAt = a.generatedAt
        return a == b
    }

    /// 監視対象のディレクトリは後から作られることがある（初めて CLI を使った、中継コマンドを登録した等）。
    @discardableResult
    private func restartWatcherIfNeeded() -> Bool {
        let candidates = [
            UsagePaths.claudeProjects,
            UsagePaths.claudeBridgeDirectory,
            UsagePaths.codexSessions,
            UsagePaths.codexArchivedSessions,
        ]
        let existing = candidates.filter { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        guard let watcher, existing != watcher.watchedPaths else { return false }
        watcher.start(paths: existing)
        return true
    }
}
