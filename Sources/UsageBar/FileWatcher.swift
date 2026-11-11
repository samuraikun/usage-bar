import CoreServices
import Foundation

/// FSEvents でディレクトリ以下のファイル変更を受け取る。
/// 通知はメインキューに届き、0.5 秒ぶんの変更がまとめて渡される。
final class FileWatcher {
    typealias Handler = (_ paths: [String], _ needsFullScan: Bool) -> Void

    private var stream: FSEventStreamRef?
    private let handler: Handler
    private(set) var watchedPaths: [String] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    deinit {
        stop()
    }

    func start(paths: [String]) {
        stop()
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
            let rescanFlags = FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs
                    | kFSEventStreamEventFlagUserDropped
                    | kFSEventStreamEventFlagKernelDropped
                    | kFSEventStreamEventFlagRootChanged
            )
            var needsFullScan = false
            for index in 0..<count where eventFlags[index] & rescanFlags != 0 {
                needsFullScan = true
            }
            watcher.handler(paths, needsFullScan)
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagWatchRoot
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            flags
        ) else { return }

        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return
        }
        stream = created
        watchedPaths = paths
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        watchedPaths = []
    }
}
