import Foundation

/// File Provider 拡張の増分列挙（M5 Phase 4）を支える、マニフェストスナップショットの
/// **世代ログ**。`NSFileProviderSyncAnchor` ↔ 世代（anchor 文字列）を対応させ、
/// `enumerateChanges(from:)` が「システムが最後に見た世代 → 現在」の diff を計算できるよう、
/// 直近 `maxGenerations` 世代のファイルマップを 1 つの JSON に永続化する。
///
/// - 書き手は **File Provider 拡張プロセスのみ**（プロセス内はアクターで直列化・atomic 書出）。
///   アプリ本体はこのファイルに触らない。
/// - これは**派生データ**（S3 のマニフェストからいつでも再生成できる）なので App Group
///   コンテナ内の `Library/Caches` に置く。消えても anchor 不明 → `.syncAnchorExpired` →
///   システムが全再列挙して自己回復するだけで実害はない。
/// - 中身は相対パスとファイルメタデータのみ（`DeletedFilesCache` と同水準。認証情報・deviceId
///   の秘匿値は含まない — deviceId はマニフェスト由来の書込元表示値で Keychain 秘匿対象ではない）。
public enum ManifestGenerationLog {

    public static let currentSchemaVersion = 1
    /// 保持する世代数。コンテナごとの anchor が数世代ずれても diff を返せる程度に持ち、
    /// それより古い anchor は `.syncAnchorExpired`（全再列挙）に倒す。
    public static let defaultMaxGenerations = 8

    /// 1 世代 = ある時点のリモート全体像。`anchor` が `NSFileProviderSyncAnchor` の中身になる。
    public struct Generation: Codable, Equatable, Sendable {
        public var anchor: String
        public var fetchedAt: Date
        /// shardId → 取得済みオブジェクト etag（次回増分ロードの比較材料）。
        public var shardEtags: [String: String]
        public var files: [String: ManifestFileEntry]

        public init(anchor: String, fetchedAt: Date, shardEtags: [String: String], files: [String: ManifestFileEntry]) {
            self.anchor = anchor
            self.fetchedAt = fetchedAt
            self.shardEtags = shardEtags
            self.files = files
        }
    }

    /// 永続ファイルの中身（純粋値・テスト可能）。
    public struct Payload: Codable, Equatable, Sendable {
        public var schemaVersion: Int
        /// このログを採った bucket。現在の bucket と不一致なら無効（別バケットの世代で diff しない）。
        public var bucket: String
        /// 古い → 新しい順。末尾が最新世代。
        public var generations: [Generation]

        public init(schemaVersion: Int, bucket: String, generations: [Generation]) {
            self.schemaVersion = schemaVersion
            self.bucket = bucket
            self.generations = generations
        }
    }

    public enum LogError: Error {
        case unsupportedVersion(found: Int, supported: Int)
    }

    // MARK: - 純粋ロジック（テスト可能）

    public static func latest(of payload: Payload?) -> Generation? {
        payload?.generations.last
    }

    public static func generation(anchor: String, in payload: Payload?) -> Generation? {
        payload?.generations.last { $0.anchor == anchor }
    }

    /// 新しいスナップショットをログへ反映する。
    /// - ファイル内容が最新世代と**同一**なら世代を増やさない（anchor 安定）。ただし shard etag と
    ///   取得時刻は最新値で更新する（同内容でシャードが書き直された場合に次回の再取得を避ける）。
    /// - 内容が変わっていれば新世代を末尾に追加し、`maxGenerations` を超えた古い世代を落とす。
    /// - Returns: 更新後 payload と、新世代が追加されたか（= 変更検知。呼び出し側の signal 契機）。
    public static func appending(
        snapshot: ManifestSnapshotLoader.SnapshotResult,
        anchor: String,
        fetchedAt: Date,
        to payload: Payload?,
        bucket: String,
        maxGenerations: Int = defaultMaxGenerations
    ) -> (payload: Payload, appended: Bool) {
        var generations = (payload?.bucket == bucket ? payload?.generations : nil) ?? []
        if var latest = generations.last, latest.files == snapshot.files {
            latest.shardEtags = snapshot.shardEtags
            latest.fetchedAt = fetchedAt
            generations[generations.count - 1] = latest
            return (Payload(schemaVersion: currentSchemaVersion, bucket: bucket, generations: generations), false)
        }
        generations.append(Generation(
            anchor: anchor, fetchedAt: fetchedAt,
            shardEtags: snapshot.shardEtags, files: snapshot.files
        ))
        if generations.count > maxGenerations {
            generations.removeFirst(generations.count - maxGenerations)
        }
        return (Payload(schemaVersion: currentSchemaVersion, bucket: bucket, generations: generations), true)
    }

    public static func encode(_ payload: Payload) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(payload)
    }

    /// JSON をデコードし、スキーマ版を検証する。新しすぎる/不一致版は `unsupportedVersion`。
    public static func decode(_ data: Data) throws -> Payload {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let payload = try dec.decode(Payload.self, from: data)
        guard payload.schemaVersion == currentSchemaVersion else {
            throw LogError.unsupportedVersion(found: payload.schemaVersion, supported: currentSchemaVersion)
        }
        return payload
    }

    // MARK: - IO（拡張プロセス専用・アクター配下で呼ぶ）

    /// 永続ファイルの既定 URL（App Group コンテナ内 `Library/Caches/Tide/`）。
    /// アプリの `factoryReset` / `make reset` の掃除範囲に含める。
    public static func defaultURL() throws -> URL {
        let dir = try TideAppGroup.cachesDirectoryURL()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("fileprovider-manifest-log.json")
    }

    /// 読込: 欠落 / 壊れ / スキーマ不一致 / bucket 不一致はすべて nil（ログ無効 = cold 扱い）。
    public static func load(bucket: String, url: URL) -> Payload? {
        guard let data = try? Data(contentsOf: url),
              let payload = try? decode(data),
              payload.bucket == bucket else { return nil }
        return payload
    }

    /// 保存: atomic 書き出し。呼び出し側はベストエフォート（失敗はログのみ）で扱う。
    public static func save(_ payload: Payload, url: URL) throws {
        try encode(payload).write(to: url, options: .atomic)
    }
}
