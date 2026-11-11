import Foundation

/// 追記され続ける JSONL ファイルを、前回読んだ位置から続けて読む。
///
/// - シンボリックリンクはたどらない（`O_NOFOLLOW`）。通常のファイル以外は読まない。
/// - ファイルが置き換えられた（inode が変わった）か短くなったときは先頭から読み直す。
/// - 書き込み途中の最後の行は、改行が来るまで手元に保留する。
/// - 1 行が `maxLineBytes` を超えたら、その行は読まずに捨てる（メモリを使い切らないため）。
public final class JSONLFileCursor {
    public let path: String
    public let maxLineBytes: Int

    public private(set) var offset: off_t = 0
    private var device: dev_t?
    private var inode: ino_t?
    private var pending = Data()
    private var discardingOversizedLine = false

    private static let chunkSize = 1 << 20

    public init(path: String, maxLineBytes: Int = 32 << 20) {
        self.path = path
        self.maxLineBytes = maxLineBytes
    }

    public enum ReadOutcome: Equatable {
        /// ファイルが無い、通常のファイルではない、または開けない。
        case unavailable
        case unchanged
        case appended
    }

    /// 新しく追記された完全な行を `onLine` に渡す。
    /// 先頭から読み直すときは、行を渡す前に `onReset` を呼ぶ。
    @discardableResult
    public func readNewLines(onReset: () -> Void = {}, onLine: (Data) -> Void) -> ReadOutcome {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return .unavailable }
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return .unavailable }

        let replaced = (device != nil && (device != st.st_dev || inode != st.st_ino))
        if replaced || st.st_size < offset {
            offset = 0
            pending.removeAll(keepingCapacity: false)
            discardingOversizedLine = false
            onReset()
        }
        device = st.st_dev
        inode = st.st_ino

        guard st.st_size > offset else { return .unchanged }

        var buffer = [UInt8](repeating: 0, count: Self.chunkSize)
        var readAny = false
        while true {
            let n = buffer.withUnsafeMutableBytes { raw in
                pread(fd, raw.baseAddress, raw.count, offset)
            }
            if n <= 0 { break }
            readAny = true
            offset += off_t(n)
            buffer.withUnsafeBytes { raw in
                consume(UnsafeRawBufferPointer(rebasing: raw[0..<n]), onLine: onLine)
            }
        }
        return readAny ? .appended : .unchanged
    }

    private func consume(_ chunk: UnsafeRawBufferPointer, onLine: (Data) -> Void) {
        guard let base = chunk.baseAddress else { return }
        var start = 0
        let count = chunk.count
        while start < count {
            let remaining = count - start
            let found = memchr(base + start, Int32(UInt8(ascii: "\n")), remaining)
            if let found {
                let end = base.distance(to: UnsafeRawPointer(found))
                if discardingOversizedLine {
                    discardingOversizedLine = false
                } else if pending.count + (end - start) > maxLineBytes {
                    pending.removeAll(keepingCapacity: false)
                } else {
                    pending.append(base.advanced(by: start).assumingMemoryBound(to: UInt8.self), count: end - start)
                    if !pending.isEmpty { onLine(pending) }
                    pending.removeAll(keepingCapacity: true)
                }
                start = end + 1
            } else {
                if !discardingOversizedLine {
                    if pending.count + remaining > maxLineBytes {
                        pending.removeAll(keepingCapacity: false)
                        discardingOversizedLine = true
                    } else {
                        pending.append(base.advanced(by: start).assumingMemoryBound(to: UInt8.self), count: remaining)
                    }
                }
                start = count
            }
        }
    }
}
