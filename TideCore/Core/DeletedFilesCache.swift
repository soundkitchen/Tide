import Foundation

/// 「Deleted files」タブの直近フル列挙結果を永続化する軽量キャッシュ（#29 (b)）。
/// タブを開いた瞬間に前回のスナップショットを即表示し、Refresh で再列挙して更新する。
/// 巨大バケットで毎回 `listObjectVersions` を全列挙する待ち時間を体感から消すのが目的。
///
/// これは **派生データ**（S3 の `listObjectVersions` からいつでも再生成できる）なので `Caches` に置く。
/// `factoryReset` は `~/Library/Caches/Tide` ごと消すのでキャッシュも自動で消える。OS が Caches を
/// 自発的に purge しても、次回 Refresh で再生成されるだけで実害はない。
///
/// 中身は削除済みファイルの**相対パス + 版メタデータ + bucket 名**のみ（認証情報は無い）。露出は
/// ローカル DB（Application Support）が既に保持しているパスメタデータと同等。
public enum DeletedFilesCache {

    public static let currentSchemaVersion = 1

    /// キャッシュファイルの中身（純粋値・テスト可能）。
    public struct Payload: Codable, Equatable, Sendable {
        public var schemaVersion: Int
        /// このスナップショットを採った bucket。現在の bucket と不一致なら無効（別バケットの一覧を出さない）。
        public var bucket: String
        /// 最後にフル列挙した時刻（UI の「Last updated …」表示用）。
        public var updatedAt: Date
        /// 削除済み（最新が delete marker）かつ復元可能なファイル群。
        public var files: [FileVersionHistory]

        public init(schemaVersion: Int, bucket: String, updatedAt: Date, files: [FileVersionHistory]) {
            self.schemaVersion = schemaVersion
            self.bucket = bucket
            self.updatedAt = updatedAt
            self.files = files
        }
    }

    public enum CacheError: Error {
        case unsupportedVersion(found: Int, supported: Int)
    }

    // MARK: - 純粋な encode / decode（テスト可能）

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
            throw CacheError.unsupportedVersion(found: payload.schemaVersion, supported: currentSchemaVersion)
        }
        return payload
    }

    /// bucket が一致する payload だけを通す純粋フィルタ（不一致は nil＝キャッシュ無効）。
    public static func validate(_ payload: Payload, bucket: String) -> Payload? {
        payload.bucket == bucket ? payload : nil
    }

    // MARK: - IO（nonisolated・off-main で呼ぶ）

    /// キャッシュファイルの既定 URL（`~/Library/Caches/Tide/deleted-files-cache.json`）。
    public static func defaultURL() throws -> URL {
        let caches = try FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let dir = caches.appendingPathComponent("Tide", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("deleted-files-cache.json")
    }

    /// 読込: 欠落 / 壊れ / スキーマ不一致 / bucket 不一致はすべて nil（キャッシュ無効）。ベストエフォート。
    public static func load(bucket: String) -> Payload? {
        guard let url = try? defaultURL(),
              let data = try? Data(contentsOf: url),
              let payload = try? decode(data) else { return nil }
        return validate(payload, bucket: bucket)
    }

    /// 保存: スナップショットを atomic 書き出し。呼び出し側はベストエフォート（失敗はログのみ）で扱う。
    public static func save(files: [FileVersionHistory], bucket: String, updatedAt: Date) throws {
        let payload = Payload(
            schemaVersion: currentSchemaVersion, bucket: bucket, updatedAt: updatedAt, files: files
        )
        let url = try defaultURL()
        try encode(payload).write(to: url, options: .atomic)
    }
}
