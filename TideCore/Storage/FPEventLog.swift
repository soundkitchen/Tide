import Foundation

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

    public init(
        timestamp: Double, bucket: String, eventType: String,
        path: String?, message: String, details: String? = nil
    ) {
        self.timestamp = timestamp
        self.bucket = bucket
        self.eventType = eventType
        self.path = path
        self.message = message
        self.details = details
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

    private let bucket: String
    private let fileURL: URL?
    private let maxBytes: Int

    /// - Parameter fileURL: nil = 永続化なし（構築失敗時の縮退。append は no-op・load は空）。
    public init(bucket: String, fileURL: URL?, maxBytes: Int = FPEventLog.defaultMaxBytes) {
        self.bucket = bucket
        self.fileURL = fileURL
        self.maxBytes = maxBytes
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
    public func append(
        type: SyncLogEventType, path: String?, message: String, details: String? = nil
    ) {
        guard let fileURL else { return }
        let record = FPEventRecord(
            timestamp: Date().timeIntervalSince1970,
            bucket: bucket,
            eventType: type.rawValue,
            path: path,
            message: message,
            details: details
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

    private static func parse(url: URL, bucket: String, byteCeiling: Int) -> [FPEventRecord] {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size <= byteCeiling,
              let data = try? Data(contentsOf: url)
        else { return [] }
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
            records.append(record)
        }
        return records
    }
}
