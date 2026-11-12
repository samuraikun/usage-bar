import Foundation
import UsageCore

// Claude Code のステータスライン用コマンド兼、その設定を行う CLI。
//
//   usagebar-bridge             ステータスラインとして動く（Claude Code から呼ばれる）
//   usagebar-bridge install     ~/.claude/settings.json の statusLine にこのコマンドを登録する
//   usagebar-bridge uninstall   登録を外す
//   usagebar-bridge status      受け取った最新の値を表示する
//
// 通信は一切しない。標準入力から数値だけを取り出し、~/.claude/usagebar/ に書くだけ。
// モデルごとの週間枠（Fable など）は標準入力に含まれないため、Claude Code が ~/.claude.json に
// 残した取得結果から、枠の名前と数値だけを読む。

let maxStdinBytes = 4 << 20

/// 中継コマンドはアプリの外で動き、アプリで選んだ言語の設定は読めないため、Mac の言語設定に従う。
let language = AppLanguage.fromSystem()

func tr(_ ja: String, _ en: String) -> String {
    language == .ja ? ja : en
}

/// 上限を超える入力は丸ごと捨てる（ファイルをリダイレクトされても上限までしか読まない）。
func readStdin(limit: Int) -> Data {
    var data = Data()
    let handle = FileHandle.standardInput
    while data.count <= limit {
        guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
        data.append(chunk)
    }
    return data.count > limit ? Data() : data
}

func ensurePrivateDirectory(_ path: String) -> Bool {
    var st = stat()
    if lstat(path, &st) == 0 {
        // 他人が作ったディレクトリやシンボリックリンクには書かない。
        guard (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid() else { return false }
        if (st.st_mode & 0o077) != 0 { chmod(path, 0o700) }
        return true
    }
    return mkdir(path, 0o700) == 0
}

/// 同じディレクトリに一時ファイルを作ってから rename し、読み手が書きかけの内容を見ないようにする。
/// 書き込み先のディレクトリは呼び出し側で確かめておく。
func writeAtomically(_ data: Data, to path: String, mode: mode_t = 0o600) -> Bool {
    let directory = (path as NSString).deletingLastPathComponent
    let temporary = directory + "/.usagebar-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).tmp"
    let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
    guard fd >= 0 else { return false }
    // umask の影響を受けないよう、作った後で権限を指定し直す。
    fchmod(fd, mode)
    let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    let closed = close(fd) == 0
    guard written == data.count, closed, rename(temporary, path) == 0 else {
        unlink(temporary)
        return false
    }
    return true
}

func shortDuration(_ seconds: TimeInterval) -> String {
    let total = seconds.isFinite ? Int(min(max(seconds, 0), 3_155_760_000)) : 0
    let days = total / 86400
    let hours = (total % 86400) / 3600
    let minutes = (total % 3600) / 60
    if days > 0 { return "\(days)d\(hours)h" }
    if hours > 0 { return "\(hours)h\(String(format: "%02d", minutes))m" }
    return "\(minutes)m"
}

func statusLineText(input: Data, snapshot: ClaudeBridgeSnapshot?, now: Date) -> String {
    struct Input: Decodable {
        struct Model: Decodable { var display_name: String? }
        struct Context: Decodable { var used_percentage: Double? }
        var model: Model?
        var context_window: Context?
    }
    let parsed = try? JSONDecoder().decode(Input.self, from: input)
    var parts: [String] = []
    if let name = parsed?.model?.display_name, !name.isEmpty {
        // 制御文字を除き、端末に表示できる文字だけを出す。
        parts.append(String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(40)))
    }
    if let snapshot {
        for (label, window) in [("5h", snapshot.five_hour), ("7d", snapshot.seven_day)] {
            guard let window else { continue }
            let remaining = window.resets_at.map { $0 - now.timeIntervalSince1970 }
            if let remaining, remaining <= 0 {
                parts.append("\(label) 0%")
                continue
            }
            var text = "\(label) \(Int(window.used_percentage.rounded()))%"
            if let remaining { text += " ↻\(shortDuration(remaining))" }
            parts.append(text)
        }
    }
    if let context = parsed?.context_window?.used_percentage, context.isFinite {
        parts.append("ctx \(Int(min(max(context, 0), 1000).rounded()))%")
    }
    return parts.joined(separator: " │ ")
}

// MARK: - settings.json の編集

enum InstallError: Error, CustomStringConvertible {
    case settingsUnreadable(String)
    case existingStatusLine(String)
    case writeFailed(String)
    case changedConcurrently
    case temporaryLocation(String)

    var description: String {
        switch self {
        case .settingsUnreadable(let detail):
            return tr("settings.json を JSON として読めませんでした: \(detail)",
                      "Could not read settings.json as JSON: \(detail)")
        case .existingStatusLine(let command):
            return tr("""
            すでに別の statusLine が設定されています:
              \(command)
            上書きしてよければ `usagebar-bridge install --force` を実行してください（元の設定はバックアップに残します）。
            """, """
            Another statusLine command is already set:
              \(command)
            To replace it, run `usagebar-bridge install --force` (the current settings are backed up first).
            """)
        case .writeFailed(let detail):
            return tr("settings.json を書き込めませんでした: \(detail)", "Could not write settings.json: \(detail)")
        case .changedConcurrently:
            return tr("読み込んでから書き込むまでの間に settings.json が書き換えられました。変更していません。もう一度実行してください。",
                      "settings.json changed while it was being updated. Nothing was changed. Please run the command again.")
        case .temporaryLocation(let path):
            return tr("""
            このコマンドはビルド用のフォルダにあります:
              \(path)
            次のビルドで消えると、Claude Code のステータスラインが動かなくなります。
            scripts/build-app.sh --install で ~/Applications に配置し、そこにある usagebar-bridge で install を実行してください。
            （このまま登録する場合は --force を付けてください）
            """, """
            This command is inside a build folder:
              \(path)
            The next build deletes it, and Claude Code's status line would stop working.
            Run scripts/build-app.sh --install, then run install with the usagebar-bridge in ~/Applications.
            (To register this path anyway, add --force.)
            """)
        }
    }
}

func shellQuoted(_ path: String) -> String { StatusLineCommand.quoted(path) }

func ownExecutablePath() -> String {
    let raw = CommandLine.arguments[0]
    let url = raw.contains("/") ? URL(fileURLWithPath: raw) : (Bundle.main.executableURL ?? URL(fileURLWithPath: raw))
    return url.standardizedFileURL.resolvingSymlinksInPath().path
}

/// 読み込んだ時点のファイルの状態。書き込む直前に比べ、Claude Code が同時に書き換えていたら止める。
struct FileFingerprint: Equatable {
    var exists: Bool
    var inode: ino_t = 0
    var size: off_t = 0
    var modifiedSeconds: Int = 0
    var modifiedNanoseconds: Int = 0

    init(path: String) {
        var st = stat()
        guard stat(path, &st) == 0 else {
            exists = false
            return
        }
        exists = true
        inode = st.st_ino
        size = st.st_size
        modifiedSeconds = st.st_mtimespec.tv_sec
        modifiedNanoseconds = st.st_mtimespec.tv_nsec
    }
}

func loadSettings(_ path: String) throws -> (settings: [String: Any], fingerprint: FileFingerprint) {
    let fingerprint = FileFingerprint(path: path)
    guard fingerprint.exists else { return ([:], fingerprint) }
    // パスで読む（URL を受け取る API は使わない）。
    guard let data = FileManager.default.contents(atPath: path) else {
        throw InstallError.settingsUnreadable(tr("読み込めませんでした", "could not read the file"))
    }
    if data.isEmpty { return ([:], fingerprint) }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw InstallError.settingsUnreadable(tr("トップレベルがオブジェクトではありません", "the top level is not an object"))
    }
    return (object, fingerprint)
}

func saveSettings(_ settings: [String: Any], to path: String, expecting fingerprint: FileFingerprint) throws {
    guard FileFingerprint(path: path) == fingerprint else { throw InstallError.changedConcurrently }
    // dotfiles 管理でシンボリックリンクになっていることがある。リンクを普通のファイルで
    // 置き換えないよう、リンク先を書き換える。
    let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    let directory = (target as NSString).deletingLastPathComponent
    var dirStat = stat()
    guard lstat(directory, &dirStat) == 0, (dirStat.st_mode & S_IFMT) == S_IFDIR, dirStat.st_uid == getuid() else {
        throw InstallError.writeFailed(tr("\(directory) が自分のディレクトリではありません", "\(directory) is not a directory you own"))
    }

    var mode: mode_t = 0o600
    var fileStat = stat()
    if lstat(target, &fileStat) == 0 {
        mode = fileStat.st_mode & 0o777
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backup = target + ".usagebar-backup-" + formatter.string(from: Date())
        try FileManager.default.copyItem(atPath: target, toPath: backup)
        chmod(backup, 0o600)
        print(tr("バックアップ: \(backup)", "Backup: \(backup)"))
    }
    let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    guard writeAtomically(data + Data("\n".utf8), to: target, mode: mode) else {
        throw InstallError.writeFailed(target)
    }
}

func isOurStatusLine(_ value: Any?) -> Bool {
    guard let statusLine = value as? [String: Any], let command = statusLine["command"] as? String else { return false }
    return StatusLineCommand.isUsageBarBridge(command)
}

func install(force: Bool) throws {
    let path = UsagePaths.claudeSettings
    let executable = ownExecutablePath()
    if !force, executable.contains("/.build/") || executable.contains("/build.noindex/") {
        throw InstallError.temporaryLocation(executable)
    }
    var settings: [String: Any]
    let fingerprint: FileFingerprint
    do { (settings, fingerprint) = try loadSettings(path) } catch let error as InstallError { throw error } catch {
        throw InstallError.settingsUnreadable(error.localizedDescription)
    }
    if let existing = settings["statusLine"], !isOurStatusLine(existing), !force {
        let command = ((existing as? [String: Any])?["command"] as? String) ?? String(describing: existing)
        throw InstallError.existingStatusLine(command)
    }
    settings["statusLine"] = [
        "type": "command",
        "command": shellQuoted(executable),
        "padding": 0,
    ] as [String: Any]
    try saveSettings(settings, to: path, expecting: fingerprint)
    print(tr("Claude Code の statusLine に登録しました: \(executable)", "Registered as Claude Code's statusLine: \(executable)"))
    print(tr("Claude Code で次に応答を受け取ったときから、UsageBar に使用率が表示されます。",
             "UsageBar shows Claude's usage from the next response Claude Code receives."))
}

func uninstall() throws {
    let path = UsagePaths.claudeSettings
    var (settings, fingerprint) = try loadSettings(path)
    guard isOurStatusLine(settings["statusLine"]) else {
        print(tr("UsageBar の statusLine は登録されていません。変更しませんでした。",
                 "UsageBar's statusLine is not registered. Nothing was changed."))
        return
    }
    settings.removeValue(forKey: "statusLine")
    try saveSettings(settings, to: path, expecting: fingerprint)
    print(tr("statusLine の登録を外しました。", "Removed the statusLine entry."))
}

func printStatus() {
    guard let snapshot = ClaudeBridgeSnapshot.load(path: UsagePaths.claudeBridgeSnapshot) else {
        print(tr("まだ値を受け取っていません（\(UsagePaths.claudeBridgeSnapshot)）。",
                 "No values received yet (\(UsagePaths.claudeBridgeSnapshot))."))
        return
    }
    let now = Date()
    let observed = Date(timeIntervalSince1970: snapshot.observed_at)
    let elapsed = shortDuration(now.timeIntervalSince(observed))
    print(tr("受信時刻: \(observed)（\(elapsed) 前）", "Received: \(observed) (\(elapsed) ago)"))
    for window in snapshot.rateLimitSnapshot.windows {
        let reset = window.resetsAt.map { tr(" / リセット \($0)", " / resets \($0)") } ?? ""
        let age = window.observedAt.map {
            let elapsed = shortDuration(now.timeIntervalSince($0))
            return tr(" / \(elapsed) 前の値", " / as of \(elapsed) ago")
        } ?? ""
        print("\(window.label(in: language)): \(window.usedPercent)%\(reset)\(age)")
    }
}

// MARK: - 入口

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case nil:
    let now = Date()
    let input = readStdin(limit: maxStdinBytes)
    let previous = ClaudeBridgeSnapshot.load(path: UsagePaths.claudeBridgeSnapshot)
    var snapshot = previous
    if var fresh = ClaudeBridgeSnapshot.fromStatusLineInput(input, now: now) {
        let models = ClaudeUsageCache.loadModelWindows(path: UsagePaths.claudeConfig)
        fresh.model_scoped = models.isEmpty ? nil : models
        let merged = fresh.merged(onto: previous, now: now)
        snapshot = merged
        if let data = try? merged.encoded(), ensurePrivateDirectory(UsagePaths.claudeBridgeDirectory) {
            _ = writeAtomically(data, to: UsagePaths.claudeBridgeSnapshot)
        }
    }
    print(statusLineText(input: input, snapshot: snapshot, now: now))
case "install":
    do { try install(force: arguments.contains("--force")) } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }
case "uninstall":
    do { try uninstall() } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }
case "status":
    printStatus()
default:
    FileHandle.standardError.write(Data((tr("使い方", "Usage") + ": usagebar-bridge [install [--force] | uninstall | status]\n").utf8))
    exit(2)
}
