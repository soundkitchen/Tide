import Foundation
import CoreServices

/// FSEvents を AsyncStream<FileChangeEvent> として配信する。
/// `start()` で開始、`stop()` で停止。複数回 start/stop は未対応（毎回新規 instance を作る）。
final class FileWatcher: @unchecked Sendable {
    let rootURL: URL

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "org.izukawa.Tide.FileWatcher")
    private var continuation: AsyncStream<FileChangeEvent>.Continuation?
    let events: AsyncStream<FileChangeEvent>

    init(rootURL: URL) {
        self.rootURL = rootURL
        var localContinuation: AsyncStream<FileChangeEvent>.Continuation!
        self.events = AsyncStream<FileChangeEvent>(bufferingPolicy: .unbounded) { cont in
            localContinuation = cont
        }
        self.continuation = localContinuation
    }

    func start() throws {
        guard stream == nil else { return }

        let pathsToWatch = [rootURL.path] as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagUseCFTypes
        )

        guard let newStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            FileWatcher.callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            flags
        ) else {
            throw SyncError.ioError(underlying: NSError(
                domain: "Tide.FileWatcher",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "FSEventStreamCreate returned nil"]
            ))
        }

        FSEventStreamSetDispatchQueue(newStream, queue)
        FSEventStreamStart(newStream)
        stream = newStream

        AppLogger.watcher.info("FileWatcher started: \(self.rootURL.path, privacy: .private)")
    }

    func stop() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
        continuation?.finish()
        continuation = nil
    }

    deinit {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
    }

    fileprivate func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
        guard let cont = continuation else { return }
        let rootPath = rootURL.path
        for (i, p) in paths.enumerated() {
            // パスを同期ルート相対に正規化
            var relative: String
            if p == rootPath {
                continue
            } else if p.hasPrefix(rootPath + "/") {
                relative = String(p.dropFirst(rootPath.count + 1))
            } else {
                continue
            }

            // ハードコード除外
            if HardcodedIgnoreRules.shouldIgnore(relativePath: relative) { continue }

            let flag = Int(flags[i])

            // ディレクトリイベントはスキップ（FileEvents 有効でもディレクトリは飛んでくる）
            if (flag & kFSEventStreamEventFlagItemIsDir) != 0 { continue }
            if (flag & kFSEventStreamEventFlagItemIsSymlink) != 0 { continue }

            // 実際にファイルが存在するかで create/modify か delete を判別する
            let fullURL = URL(fileURLWithPath: rootPath).appendingPathComponent(relative)
            let exists = FileManager.default.fileExists(atPath: fullURL.path)
            let event = FileChangeEvent(
                relativePath: relative,
                kind: exists ? .createdOrModified : .deleted
            )
            cont.yield(event)
        }
    }

    /// C コールバック。クラスメソッド (static) として実装する必要がある。
    private static let callback: FSEventStreamCallback = { (
        _ stream,
        clientCallBackInfo,
        numEvents,
        eventPaths,
        eventFlags,
        _
    ) in
        guard let info = clientCallBackInfo else { return }
        let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()

        let cfPaths = unsafeBitCast(eventPaths, to: CFArray.self)
        let count = CFArrayGetCount(cfPaths)
        var paths: [String] = []
        paths.reserveCapacity(count)
        for i in 0..<count {
            let ptr = CFArrayGetValueAtIndex(cfPaths, i)
            let cf = unsafeBitCast(ptr, to: CFString.self)
            paths.append(cf as String)
        }

        var flags: [FSEventStreamEventFlags] = []
        flags.reserveCapacity(numEvents)
        for i in 0..<numEvents {
            flags.append(eventFlags[i])
        }

        watcher.handle(paths: paths, flags: flags)
    }
}
