import Foundation

/// Claude Code が `~/.claude.json` に残す、利用上限の取得結果（`cachedUsageUtilization`）の読み取り。
///
/// Fable などモデルごとの週間枠は、ステータスラインの入力には含まれない。Claude Code が
/// `/usage` の表示などのために取得した結果をこのファイルに残すので、中継コマンドがそこから
/// 枠の名前・使用率・リセット時刻・取得時刻だけを取り出す。ファイルのほかの内容
/// （アカウントやプロジェクトの情報）は読み捨て、どこにも書かない。
///
/// 公開された仕様ではないため、形が変わっていたら何も返さない。
public enum ClaudeUsageCache {
    /// 履歴の多い利用者では数 MB になる。それより極端に大きいものは読まない。
    public static let maxFileBytes = 32 * 1024 * 1024

    public static func modelWindows(fromClaudeConfig data: Data) -> [ClaudeBridgeSnapshot.ModelWindow] {
        struct Config: Decodable { var cachedUsageUtilization: Cache? }
        struct Cache: Decodable {
            var fetchedAtMs: Double?
            var utilization: Utilization?
        }
        struct Utilization: Decodable { var limits: [Lenient<Limit>]? }
        struct Limit: Decodable {
            var kind: String?
            var percent: Double?
            var resets_at: Moment?
            var scope: Scope?
        }
        struct Scope: Decodable { var model: Model? }
        struct Model: Decodable { var display_name: String? }

        guard let cache = (try? JSONDecoder().decode(Config.self, from: data))?.cachedUsageUtilization,
              let fetchedAtMs = cache.fetchedAtMs, fetchedAtMs.isFinite else { return [] }
        let observedAt = fetchedAtMs / 1000
        guard EpochRange.isPlausible(observedAt) else { return [] }

        let windows = (cache.utilization?.limits ?? []).compactMap { entry -> ClaudeBridgeSnapshot.ModelWindow? in
            guard let limit = entry.value, limit.kind == "weekly_scoped",
                  let name = limit.scope?.model?.display_name,
                  let percent = limit.percent else { return nil }
            return ClaudeBridgeSnapshot.ModelWindow(
                display_name: name,
                used_percentage: percent,
                resets_at: limit.resets_at?.seconds,
                observed_at: observedAt
            )
        }
        // 名前や値の範囲は、ファイルから読むときと同じ規則で整える。
        return ClaudeBridgeSnapshot(observed_at: observedAt, five_hour: nil, seven_day: nil, spend_limit: nil, model_scoped: windows)
            .sanitized().model_scoped ?? []
    }

    /// 大きさの上限を守って読む。読めない・形が違うときは空。
    public static func loadModelWindows(path: String) -> [ClaudeBridgeSnapshot.ModelWindow] {
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              st.st_size > 0, st.st_size <= off_t(maxFileBytes) else { return [] }
        var buffer = [UInt8](repeating: 0, count: Int(st.st_size))
        var filled = 0
        while filled < buffer.count {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress! + filled, $0.count - filled) }
            guard n > 0 else { return [] }
            filled += n
        }
        return modelWindows(fromClaudeConfig: Data(buffer))
    }

    /// 配列の 1 要素が想定外の形でも、ほかの要素を読めるようにする。
    private struct Lenient<Value: Decodable>: Decodable {
        var value: Value?
        init(from decoder: Decoder) throws {
            value = try? Value(from: decoder)
        }
    }

    /// リセット時刻。ISO 8601 の文字列（小数秒つき）か、エポック秒の数値で届く。
    private struct Moment: Decodable {
        var seconds: Double?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) {
                seconds = number.rounded(.down)
            } else if let text = try? container.decode(String.self) {
                seconds = Self.parse(text)
            }
        }

        static func parse(_ text: String) -> Double? {
            guard text.utf8.count <= 64 else { return nil }
            // 小数秒は桁数がまちまち（マイクロ秒まで）なので、取り除いてから読む。
            var plain = text
            if let dot = plain.firstIndex(of: ".") {
                let end = plain[dot...].dropFirst().firstIndex { !$0.isNumber } ?? plain.endIndex
                plain.removeSubrange(dot..<end)
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: plain)?.timeIntervalSince1970
        }
    }
}
