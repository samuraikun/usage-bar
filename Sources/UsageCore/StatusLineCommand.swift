import Foundation

/// `~/.claude/settings.json` の `statusLine.command` に書くコマンド文字列。
public enum StatusLineCommand {
    /// パス全体を単一引用符で囲み、シェルに解釈させない。
    public static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// install が書いた形（usagebar-bridge の絶対パスだけ）と一致するときだけ true。
    /// `my.sh | usagebar-bridge` のように利用者が組み立てたコマンドは、上書きも削除もしない。
    public static func isUsageBarBridge(_ command: String) -> Bool {
        let path: String
        if command.hasPrefix("'"), command.hasSuffix("'"), command.count >= 2 {
            // 引用符を外した結果を囲み直して、元の文字列に戻るかで確かめる。
            let unquoted = String(command.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
            guard quoted(unquoted) == command else { return false }
            path = unquoted
        } else {
            guard command.rangeOfCharacter(from: CharacterSet(charactersIn: " \t\n|;&$`<>(){}\"\\'*?[]#~")) == nil else { return false }
            path = command
        }
        return path.hasPrefix("/") && path.hasSuffix("/usagebar-bridge")
    }
}
