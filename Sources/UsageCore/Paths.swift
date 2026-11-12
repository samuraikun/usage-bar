import Foundation

/// 読み取るファイルの場所。
///
/// App Sandbox の中では `NSHomeDirectory()` がコンテナのパスを返すため、
/// passwd データベースから本来のホームディレクトリを取る。
/// ここに挙げたパス以外は entitlements でも読み取りを許可していない。
public enum UsagePaths {
    public static var realHome: String {
        var pwd = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 4096)
        if getpwuid_r(getuid(), &pwd, &buffer, buffer.count, &result) == 0,
           result != nil,
           let dir = pwd.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    public static var claudeProjects: String { realHome + "/.claude/projects" }
    public static var claudeBridgeDirectory: String { realHome + "/.claude/usagebar" }
    public static var claudeBridgeSnapshot: String { claudeBridgeDirectory + "/claude-rate-limits.json" }
    /// Claude Code 自身の状態ファイル。中継コマンドだけが、モデルごとの枠を取り出すために読む（アプリは読めない）。
    public static var claudeConfig: String { realHome + "/.claude.json" }
    public static var claudeSettings: String { realHome + "/.claude/settings.json" }
    public static var codexSessions: String { realHome + "/.codex/sessions" }
    public static var codexArchivedSessions: String { realHome + "/.codex/archived_sessions" }
}
