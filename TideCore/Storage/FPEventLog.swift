import Foundation
import notify

/// FP 拡張の同期活動 1 件ぶんの軽量ログレコード（Issue #83・fpOnly の Sync Activity 復権）。
/// DB の `SyncLogRecord` と同じ表示語彙へ写像できる形で持つ（`eventType` =
/// `SyncLogEventType.rawValue`・path / message / details は英語生文字列 = UI では
/// `Text(verbatim:)` で出す）。`bucket` はレコード単位で持ち、読込側がバケット切替後の
/// stale イベント混入を弾くためのキー（`PersistedPathSet` の bucket キーと同じ役割）。
public struct FPEventRecord: Codable, Sendable, Equatable {
    public var timestamp: Double
    public var bucket: String
    public var eventType: String
    public var path: String?
    public var message: String
    public var details: String?
    /// ユーザへ OS 通知で知らせる出来事なら、その種類（`FPEventNotice.rawValue`・Issue #147）。
    /// 通知しないイベントと #147 より前のレコードは nil（キー自体が無い行もそのまま読める）。
    public var notice: String?

    public init(
        timestamp: Double, bucket: String, eventType: String,
        path: String?, message: String, details: String? = nil, notice: String? = nil
    ) {
        self.timestamp = timestamp
        self.bucket = bucket
        self.eventType = eventType
        self.path = path
        self.message = message
        self.details = details
        self.notice = notice
    }
}

/// FP 拡張のイベントのうち、アプリが OS 通知で知らせるものの種類（Issue #147）。
/// 拡張が `FPEventLog.append(notice:)` で印を付け、アプリの `FPEventNoticeWatcher` が新着を
/// 拾って通知する。どれも「ファイルがこの Mac にだけ残り、バックアップされない」出来事で、
/// ユーザが意図していない可能性があるものに限る（機密網・`.syncignore` による新規作成の除外は、
/// 意図した除外なので印を付けない）。
///
/// 通知に出す名前の出どころ（`subject`）は種類で決まる:
/// - `unsyncableName` / `renamedFileExcluded` / `renamedFolderExcluded`: `details`（表示用の
///   パス。検証できない名前は `path` に入れられず、改名は新しい名前を出したいため）
/// - `symbolicLink` / `packageHasUnsyncableItem` / `packageTooManyFiles`: `path`
public enum FPEventNotice: String, Sendable, CaseIterable {
    /// 同期できない名前（バックスラッシュ等）で新規作成された
    case unsyncableName
    /// symlink が新規作成された
    case symbolicLink
    /// 追跡中のファイルが同期しない名前へ改名され、バックアップから外れた
    case renamedFileExcluded
    /// 追跡中のファイルを含むフォルダが同期しない名前へ改名され、配下がバックアップから外れた
    case renamedFolderExcluded
    /// パッケージにシンボリックリンク・通常のファイルでない項目・同期できない名前が入っていて、
    /// パッケージごと除外した（#140）
    case packageHasUnsyncableItem
    /// パッケージの中身が上限（`PackageScanner.memberLimit`）を超えていて、パッケージごと除外した（#140）
    case packageTooManyFiles

    /// fileproviderd が同じアイテムの除外を再送する種類か（#120 の再送嵐）。再送される種類は、
    /// アプリ側で同じアイテムを 1 回だけ通知する。改名の除外は後片付けの deleteItem で終わり、
    /// 再送されない。
    public var isResentByDaemon: Bool {
        switch self {
        case .unsyncableName, .symbolicLink, .packageHasUnsyncableItem, .packageTooManyFiles: return true
        case .renamedFileExcluded, .renamedFolderExcluded: return false
        }
    }

    /// 通知に出す名前（表示用のパス）。上の型コメントの規約どおり。
    public func subject(of record: FPEventRecord) -> String? {
        switch self {
        case .symbolicLink, .packageHasUnsyncableItem, .packageTooManyFiles: return record.path
        case .unsyncableName, .renamedFileExcluded, .renamedFolderExcluded: return record.details
        }
    }
}

/// FP 拡張イベント（書込・materialize・エラー等）の追記型 JSONL 共有ストア（Issue #83）。
/// fpOnly はアプリが DB を開かない（凍結温存）ため、DB 由来の Sync Activity が縮退する —
/// 拡張がここへ軽量ログし、アプリ UI が読んで FP 版 Sync Activity として表示する。
///
/// - 形式: 1 行 1 イベントの JSON（JSONL）。追記のみ・書き手は **FP 拡張プロセスのみ**
///   （actor 直列化 = プロセス内、単一書き手 = プロセス間。アプリ側は読むだけ）。
///   将来アプリ側イベントを足す場合は**別ファイル**（例: `fp-events-app.jsonl`）を増やし
///   読み時マージする — 同一ファイルへの多プロセス追記はしない（2026-07-26 ユーザ確定）。
/// - ローテーション: 追記後にサイズが `maxBytes` を超えたら現行 → `.1` へ退避（旧 `.1` は破棄）。
///   保持は現行 + 1 世代 = 実効 2〜4MB ≒ 数千〜1 万件。それ以前は失われる（診断ログ・安全側）。
/// - 置き場: App Group Caches（`PersistedPathSet` / 世代ログと同格・factoryReset / `make reset`
///   の掃除範囲）。拡張の **DB 非接触**は維持（GRDB 非依存の素のファイル）。
/// - 読込時の再検証（security/low.md L16 の規約): ディスク上のファイルはプロセス外で改ざん /
///   破損しうる。壊れ行（書きかけ途中の末尾行を含む）はスキップ、bucket 不一致 / 未知
///   eventType / 不正 path のレコードは破棄、message / details は長さ上限で切る。表示専用
///   （path を FS 操作に使わない）ため、`PersistedPathSet` の「1 件でも不正なら全体破棄」では
///   なく**行単位の破棄**で足りる。肥大ファイル（改ざん）は読込ごと拒否（サイズ上限 2×maxBytes）。
/// - 書込は best-effort: 失敗しても呼び出し元の FP 操作は失敗させない（ログのみ）。
public actor FPEventLog {
    public static let defaultMaxBytes = 2 * 1024 * 1024
    /// 読込時の 1 レコードあたり表示文字列の安全弁（改ざんファイル由来のメモリ肥大防止）。
    public static let maxMessageLength = 500
    public static let maxDetailsLength = 4096

    /// 追記したことをアプリへ知らせる Darwin 通知の名前（Issue #148）。sandbox の中から
    /// プロセスをまたいで届けるため、App Group の ID を前に付ける。
    public static let defaultChangeNotificationName = "\(TideAppGroup.identifier).fp-events"

    private let bucket: String
    private let fileURL: URL?
    private let maxBytes: Int
    private let changeNotificationName: String?

    /// - Parameters:
    ///   - fileURL: nil = 永続化なし（構築失敗時の縮退。append は no-op・load は空）。
    ///   - changeNotificationName: 追記のたびに送る Darwin 通知の名前（書き手 = 拡張だけが渡す・Issue #148）。
    ///     nil = 送らない（読み手のアプリ・テスト）。
    public init(
        bucket: String, fileURL: URL?, maxBytes: Int = FPEventLog.defaultMaxBytes,
        changeNotificationName: String? = nil
    ) {
        self.bucket = bucket
        self.fileURL = fileURL
        self.maxBytes = maxBytes
        self.changeNotificationName = changeNotificationName
    }

    /// 永続ファイルの既定 URL（App Group コンテナ内 `Library/Caches/Tide/`）。
    /// ファイル名の `-ext` は書き手（拡張プロセス）の識別子 — 将来のアプリ側書き手は別名で増やす。
    public static func defaultURL() throws -> URL {
        let dir = try TideAppGroup.cachesDirectoryURL()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("fp-events-ext.jsonl")
    }

    private var rotatedURL: URL? {
        fileURL.map { URL(fileURLWithPath: $0.path + ".1") }
    }

    // MARK: - 書込（FP 拡張プロセス専用）

    /// 1 イベント追記（best-effort・失敗はログのみ）。
    /// - Parameter notice: アプリに OS 通知で知らせる出来事なら、その種類（Issue #147）。
    public func append(
        type: SyncLogEventType, path: String?, message: String, details: String? = nil,
        notice: FPEventNotice? = nil
    ) {
        guard let fileURL else { return }
        let record = FPEventRecord(
            timestamp: Date().timeIntervalSince1970,
            bucket: bucket,
            eventType: type.rawValue,
            path: path,
            message: message,
            details: details,
            notice: notice?.rawValue
        )
        do {
            var data = try JSONEncoder().encode(record)  // 1 行 JSON（改行は JSON 文字列内で必ずエスケープされる）
            data.append(0x0A)
            let fm = FileManager.default
            if !fm.fileExists(atPath: fileURL.path) {
                guard fm.createFile(atPath: fileURL.path, contents: nil) else {
                    AppLogger.fileProvider.error("FP event log: cannot create file (event dropped)")
                    return
                }
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            try handle.write(contentsOf: data)
            if end + UInt64(data.count) >= UInt64(maxBytes) {
                try rotate()
            }
            if let changeNotificationName {
                notify_post(changeNotificationName)
            }
        } catch {
            AppLogger.fileProvider.error("FP event log append failed: \(String(describing: error), privacy: .private)")
        }
    }

    /// 現行ファイル → `.1` へ退避（旧 `.1` は破棄）。次の追記が新しい現行ファイルを作る。
    /// 単一書き手 + actor 直列化なのでローテーションに競合は無い。
    private func rotate() throws {
        guard let fileURL, let rotatedURL else { return }
        let fm = FileManager.default
        if fm.fileExists(atPath: rotatedURL.path) {
            try fm.removeItem(at: rotatedURL)
        }
        try fm.moveItem(at: fileURL, to: rotatedURL)
    }

    // MARK: - 読込（アプリプロセス）

    /// 追記の Darwin 通知（`changeNotificationName`）を受け取る（Issue #148）。受け取りは `queue` で行う。
    /// 返した値を捨てると受け取りをやめる。登録できなければ nil（呼び出し側は定期の確認だけで動く）。
    /// 通知は合体しうる（続けて送られた複数の通知が 1 回になる）ので、受け取ったら新着をまとめて読むこと。
    public nonisolated static func observeChanges(
        name: String = FPEventLog.defaultChangeNotificationName,
        queue: DispatchQueue = .main,
        handler: @escaping @Sendable () -> Void
    ) -> ChangeObservation? {
        var token: Int32 = 0
        let status = notify_register_dispatch(name, &token, queue) { _ in handler() }
        guard status == NOTIFY_STATUS_OK else {
            AppLogger.ui.error("FP event log: cannot observe change notifications (status \(status))")
            return nil
        }
        return ChangeObservation(token: token)
    }

    /// `observeChanges` の受け取りの登録。解放すると受け取りをやめる。
    public final class ChangeObservation: Sendable {
        private let token: Int32

        fileprivate init(token: Int32) {
            self.token = token
        }

        deinit {
            notify_cancel(token)
        }
    }

    /// 全レコードを時系列（古い → 新しい）で返す。呼ぶたびにディスクを読み直す。
    /// 書き手（拡張）が追記中の書きかけ末尾行はデコード失敗 = スキップされ、次回読込で載る。
    /// `.1` → 現行の 2 ファイル読取は非アトミック（クロスプロセス）— 読取の合間に拡張側の
    /// rotate が挟まると、その 1 回だけ「旧現行だった世代」が欠落して見える（ディスク上は
    /// 無傷・次回読込で復帰する transient。診断ビュー用途なので許容・PR #90 レビュー nit 1）。
    public func loadRecords() -> [FPEventRecord] {
        guard let fileURL, let rotatedURL else { return [] }
        var records: [FPEventRecord] = []
        for url in [rotatedURL, fileURL] {
            records.append(contentsOf: Self.parse(url: url, bucket: bucket, byteCeiling: maxBytes * 2))
        }
        return records
    }

    /// 差分読みの位置（Issue #148）: 最後に読んだファイルの inode と、そのファイルで読み終えたバイト位置。
    public struct ReadPosition: Equatable, Sendable {
        public let inode: UInt64
        public let offset: UInt64

        public init(inode: UInt64, offset: UInt64) {
            self.inode = inode
            self.offset = offset
        }
    }

    /// 前回の位置から先の新着だけを、時系列（古い → 新しい）で読む（Issue #148）。
    /// 新着を見張る側（`FPEventNoticeWatcher`）が、拡張の書込のたびに全体を読み直さないために使う。
    ///
    /// - 位置が nil（初回）: `.1` と現行を頭から全部読む。
    /// - 位置の inode が現行と同じ: 現行を位置から読む。現行が位置より短ければ（作り直された）頭から読む。
    /// - 位置の inode が `.1` と同じ（前回読んだあとにローテーションした）: `.1` を位置から読み、現行を頭から読む。
    /// - どちらとも違う（2 回以上ローテーションした等）: `.1` と現行を頭から読む（その間の世代は失われている）。
    ///
    /// 改行で終わっていない末尾の行（拡張が書きかけ）は読まず、次回その行の頭から読む。
    /// 現行を `.1` より先に開くので、開く合間にローテーションしても 2 つが同じ inode になるだけで
    /// （そのときは 1 つとして扱う）、読み飛ばしは起きない。
    /// - Returns: 読んだレコードと次の位置。ファイルが 1 つも無ければ位置は渡したまま。
    public func readNew(since position: ReadPosition?) -> (records: [FPEventRecord], position: ReadPosition?) {
        guard let fileURL, let rotatedURL else { return ([], position) }
        let current = OpenedLog(url: fileURL)
        var rotated = OpenedLog(url: rotatedURL)
        if let c = current, let r = rotated, c.inode == r.inode { rotated = nil }
        defer {
            current?.close()
            rotated?.close()
        }
        let ceiling = UInt64(maxBytes * 2)

        // 読む順（古い → 新しい）と、それぞれの読み始めの位置
        var plan: [(OpenedLog, UInt64)] = []
        if let position, let current, position.inode == current.inode {
            plan = [(current, position.offset <= current.size ? position.offset : 0)]
        } else if let position, let rotated, position.inode == rotated.inode {
            plan = [(rotated, min(position.offset, rotated.size))]
            if let current { plan.append((current, 0)) }
        } else {
            if let rotated { plan.append((rotated, 0)) }
            if let current { plan.append((current, 0)) }
        }
        guard !plan.isEmpty else { return ([], position) }

        var records: [FPEventRecord] = []
        var next = position
        for (log, start) in plan {
            // 肥大ファイル（改ざん）は読まずに末尾まで読んだことにする（loadRecords と同じ上限）
            guard log.size <= ceiling else {
                next = ReadPosition(inode: log.inode, offset: log.size)
                continue
            }
            let data = log.read(from: start)
            // 最後の改行まで（書きかけの末尾行は次回へ）
            let consumed = data.lastIndex(of: 0x0A).map { data.distance(from: data.startIndex, to: $0) + 1 } ?? 0
            records.append(contentsOf: Self.parse(data: data.prefix(consumed), bucket: bucket))
            next = ReadPosition(inode: log.inode, offset: start + UInt64(consumed))
        }
        return (records, next)
    }

    /// 読むために開いたログファイル 1 つ（inode とサイズは開いた FD から取る）。
    private struct OpenedLog {
        let handle: FileHandle
        let inode: UInt64
        let size: UInt64

        init?(url: URL) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            var st = stat()
            guard fstat(handle.fileDescriptor, &st) == 0 else {
                try? handle.close()
                return nil
            }
            self.handle = handle
            self.inode = UInt64(st.st_ino)
            self.size = UInt64(st.st_size)
        }

        /// `start` から開いた時点のサイズまでを読む（その後の追記は次回）。
        func read(from start: UInt64) -> Data {
            guard start < size, (try? handle.seek(toOffset: start)) != nil else { return Data() }
            return (try? handle.read(upToCount: Int(size - start))) ?? Data()
        }

        func close() {
            try? handle.close()
        }
    }

    private static func parse(url: URL, bucket: String, byteCeiling: Int) -> [FPEventRecord] {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size <= byteCeiling,
              let data = try? Data(contentsOf: url)
        else { return [] }
        return parse(data: data, bucket: bucket)
    }

    /// JSONL の行を検証してレコードにする（壊れ行・bucket 不一致・未知の種類・不正 path は捨てる）。
    private static func parse(data: Data, bucket: String) -> [FPEventRecord] {
        let decoder = JSONDecoder()
        var records: [FPEventRecord] = []
        for line in data.split(separator: 0x0A) {
            guard var record = try? decoder.decode(FPEventRecord.self, from: line) else { continue }
            guard record.bucket == bucket else { continue }
            guard SyncLogEventType(rawValue: record.eventType) != nil else { continue }
            if let path = record.path {
                guard (try? PathValidator.validateRelativePath(path)) != nil else { continue }
            }
            record.message = String(record.message.prefix(maxMessageLength))
            if let details = record.details {
                record.details = String(details.prefix(maxDetailsLength))
            }
            // 未知の通知種類はレコードごと捨てず、印だけ外す（表示には使えるため）
            if let notice = record.notice, FPEventNotice(rawValue: notice) == nil {
                record.notice = nil
            }
            records.append(record)
        }
        return records
    }
}
