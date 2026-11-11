import Foundation

/// Claude Code のステータスラインから受け取った利用上限を、アプリへ渡すためのファイル形式。
///
/// Claude Code はステータスライン用のコマンドに `rate_limits`（5 時間枠・週間枠の使用率と
/// リセット時刻）を標準入力で渡す。中継コマンド `usagebar-bridge` はそこから数値だけを取り出して
/// このファイルに書き、アプリはこのファイルを読むだけにする。アプリ自身は認証情報に触れず、通信もしない。
public struct ClaudeBridgeSnapshot: Codable, Equatable, Sendable {
    public struct Window: Codable, Equatable, Sendable {
        public var used_percentage: Double
        public var resets_at: Double?

        public init(used_percentage: Double, resets_at: Double?) {
            self.used_percentage = used_percentage
            self.resets_at = resets_at
        }
    }

    public static let currentVersion = 1
    /// 想定より大きいファイルは読まない。正しい内容なら 1KB に満たない。
    public static let maxFileBytes = 64 * 1024

    public var version: Int
    public var observed_at: Double
    public var five_hour: Window?
    public var seven_day: Window?
    public var spend_limit: Window?

    public init(version: Int = ClaudeBridgeSnapshot.currentVersion, observed_at: Double, five_hour: Window?, seven_day: Window?, spend_limit: Window?) {
        self.version = version
        self.observed_at = observed_at
        self.five_hour = five_hour
        self.seven_day = seven_day
        self.spend_limit = spend_limit
    }

    /// ステータスラインの入力 JSON から、利用上限の数値だけを取り出す。
    /// `rate_limits` が無い（API キー利用時や、まだ応答が無いとき）は nil。
    public static func fromStatusLineInput(_ data: Data, now: Date) -> ClaudeBridgeSnapshot? {
        struct Input: Decodable {
            var rate_limits: Limits?
        }
        struct Limits: Decodable {
            var five_hour: Window?
            var seven_day: Window?
            var spend_limit: Window?
        }
        guard let input = try? JSONDecoder().decode(Input.self, from: data),
              let limits = input.rate_limits else { return nil }
        let snapshot = ClaudeBridgeSnapshot(
            observed_at: now.timeIntervalSince1970,
            five_hour: limits.five_hour,
            seven_day: limits.seven_day,
            spend_limit: limits.spend_limit
        ).sanitized()
        guard snapshot.five_hour != nil || snapshot.seven_day != nil || snapshot.spend_limit != nil else { return nil }
        return snapshot
    }

    /// 範囲外の値や非有限値を落とす。ファイルは他のプロセスでも書けるため、読む側でも必ず通す。
    public func sanitized() -> ClaudeBridgeSnapshot {
        func clean(_ window: Window?) -> Window? {
            guard let window, window.used_percentage.isFinite else { return nil }
            let percent = min(max(window.used_percentage, 0), 1000)
            let resets = window.resets_at.flatMap { EpochRange.isPlausible($0) ? $0 : nil }
            return Window(used_percentage: percent, resets_at: resets)
        }
        return ClaudeBridgeSnapshot(
            version: version,
            observed_at: EpochRange.isPlausible(observed_at) ? observed_at : EpochRange.min,
            five_hour: clean(five_hour),
            seven_day: clean(seven_day),
            spend_limit: clean(spend_limit)
        )
    }

    /// 前回書いた値と合わせる。
    ///
    /// 複数の Claude Code を同時に開いていると、しばらく応答を受けていないセッションが
    /// 古い値でステータスラインを描き直すことがある。そのまま書くと、別のセッションが書いた
    /// 新しい値を古い値で上書きしてしまう。同じ枠（リセット時刻が同じ）の使用率は減らないので、
    /// 枠ごとに次の規則で新しい方を選ぶ。
    /// - リセット時刻が後の方を新しい枠として採る
    /// - リセット時刻が同じなら使用率が大きい方を採る
    /// - 今回届かなかった枠は、前回の値がまだリセット前なら残す
    public func merged(onto previous: ClaudeBridgeSnapshot?, now: Date) -> ClaudeBridgeSnapshot {
        guard let previous else { return self }
        let nowSeconds = now.timeIntervalSince1970
        func pick(_ new: Window?, _ old: Window?) -> Window? {
            guard let old else { return new }
            let oldAlive = (old.resets_at ?? .infinity) > nowSeconds
            guard let new else { return oldAlive ? old : nil }
            guard oldAlive, let oldReset = old.resets_at, let newReset = new.resets_at else { return new }
            // リセット時刻は秒の丸めで数秒ずれることがあるため、1 分以内は同じ枠とみなす。
            if abs(newReset - oldReset) <= 60 {
                return new.used_percentage >= old.used_percentage ? new : old
            }
            return newReset > oldReset ? new : old
        }
        return ClaudeBridgeSnapshot(
            version: version,
            observed_at: observed_at,
            five_hour: pick(five_hour, previous.five_hour),
            seven_day: pick(seven_day, previous.seven_day),
            spend_limit: pick(spend_limit, previous.spend_limit)
        )
    }

    public var rateLimitSnapshot: RateLimitSnapshot {
        var windows: [RateWindow] = []
        if let five_hour {
            windows.append(RateWindow(id: "five_hour", usedPercent: five_hour.used_percentage, windowMinutes: 300, resetsAt: five_hour.resets_at.map(Date.init(timeIntervalSince1970:))))
        }
        if let seven_day {
            windows.append(RateWindow(id: "seven_day", usedPercent: seven_day.used_percentage, windowMinutes: 10080, resetsAt: seven_day.resets_at.map(Date.init(timeIntervalSince1970:))))
        }
        if let spend_limit {
            windows.append(RateWindow(id: "spend_limit", usedPercent: spend_limit.used_percentage, windowMinutes: nil, resetsAt: spend_limit.resets_at.map(Date.init(timeIntervalSince1970:))))
        }
        return RateLimitSnapshot(observedAt: Date(timeIntervalSince1970: observed_at), windows: windows)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// シンボリックリンクをたどらず、サイズの上限を守って読む。
    public static func load(path: String) -> ClaudeBridgeSnapshot? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              st.st_size > 0, st.st_size <= off_t(maxFileBytes) else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(st.st_size))
        let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        guard n == Int(st.st_size) else { return nil }
        guard let snapshot = try? JSONDecoder().decode(ClaudeBridgeSnapshot.self, from: Data(buffer)),
              snapshot.version == currentVersion else { return nil }
        return snapshot.sanitized()
    }
}
