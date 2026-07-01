import Foundation

/// `NoFollowFileReader.init` が失敗したときの理由。
public enum FileOpenError: Error {
    /// 最終コンポーネントがシンボリックリンクだった（open が ELOOP を返した）。
    case isSymbolicLink
    /// パスが存在しない（ENOENT）。
    case notFound
    /// その他の I/O エラー（errno を保持）。
    case io(errno: Int32)
}

/// 最終コンポーネントの symlink を追従せず（`O_NOFOLLOW`）にファイルを開き、
/// 単一の FD から逐次読込する。ハッシュ計算と本体読込を 1 回の open で賄うことで、
/// 「ハッシュ用 open → 本体用 open」の 2 回 open に存在した TOCTOU 窓（M5 / F3 / L9）を畳む。
///
/// 注意: `O_NOFOLLOW` は **最終コンポーネントのみ** symlink を弾く。祖先ディレクトリの
/// symlink 経由のルート脱出は対象外で、呼び出し側の `PathValidator.resolveSafely`（字句検証）と
/// フルスキャン / FSEvents の symlink スキップに委ねる。
public final class NoFollowFileReader {
    private let fd: Int32
    private var closed = false

    public init(path: String) throws {
        let opened = path.withCString { open($0, O_RDONLY | O_NOFOLLOW) }
        if opened < 0 {
            let err = errno
            switch err {
            case ELOOP:
                throw FileOpenError.isSymbolicLink
            case ENOENT:
                throw FileOpenError.notFound
            default:
                throw FileOpenError.io(errno: err)
            }
        }
        self.fd = opened
    }

    deinit {
        if !closed { Darwin.close(fd) }
    }

    public func close() {
        if !closed {
            Darwin.close(fd)
            closed = true
        }
    }

    public struct FileInfo {
        public let size: Int64
        public let mtime: Date

        public init(size: Int64, mtime: Date) {
            self.size = size
            self.mtime = mtime
        }
    }

    /// 開いている FD を `fstat(2)` し、サイズと mtime を返す。
    /// 読込と同じ inode の情報なので、パス再 stat の TOCTOU を避けられる。
    public func info() throws -> FileInfo {
        var st = stat()
        if fstat(fd, &st) != 0 {
            throw FileOpenError.io(errno: errno)
        }
        let mt = st.st_mtimespec
        let mtime = Date(timeIntervalSince1970: Double(mt.tv_sec) + Double(mt.tv_nsec) / 1_000_000_000)
        return FileInfo(size: Int64(st.st_size), mtime: mtime)
    }

    /// 最大 `count` バイトを読む。内部で `read(2)` を繰り返し、`count` バイト集めるか EOF まで読む
    /// （regular file でも短い read があり得るため。マルチパートの中間パートが 5MiB を割らないようにする）。
    /// クリーン EOF で何も読めなければ `nil` を返す。
    public func readChunk(_ count: Int) throws -> Data? {
        guard count > 0 else { return nil }
        var buffer = Data(count: count)
        var total = 0
        try buffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            while total < count {
                let n = Darwin.read(fd, base + total, count - total)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw FileOpenError.io(errno: errno)
                }
                if n == 0 { break }   // EOF
                total += n
            }
        }
        if total == 0 { return nil }  // EOF, 何も読めなかった
        if total < count {
            buffer.removeSubrange(total..<count)
        }
        return buffer
    }
}
