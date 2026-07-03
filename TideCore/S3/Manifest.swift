import Foundation

public struct ManifestIndex: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var updatedAt: String       // ISO8601 UTC
    public var updatedBy: String       // device id
    public var shards: [String: ShardInfo]

    public init(version: Int = 1, updatedAt: String, updatedBy: String, shards: [String: ShardInfo]) {
        self.version = version
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
        self.shards = shards
    }

    public struct ShardInfo: Codable, Equatable, Sendable {
        public var etag: String
        public var count: Int

        public init(etag: String, count: Int) {
            self.etag = etag
            self.count = count
        }
    }

    public enum CodingKeys: String, CodingKey {
        case version
        case updatedAt = "updated_at"
        case updatedBy = "updated_by"
        case shards
    }

    public static func empty(updatedBy deviceId: String) -> ManifestIndex {
        ManifestIndex(
            version: 1,
            updatedAt: ISO8601.now(),
            updatedBy: deviceId,
            shards: [:]
        )
    }
}

public struct ManifestShard: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var shardId: String
    public var updatedAt: String
    public var files: [String: ManifestFileEntry]

    public init(version: Int = 1, shardId: String, updatedAt: String, files: [String: ManifestFileEntry]) {
        self.version = version
        self.shardId = shardId
        self.updatedAt = updatedAt
        self.files = files
    }

    public enum CodingKeys: String, CodingKey {
        case version
        case shardId = "shard_id"
        case updatedAt = "updated_at"
        case files
    }

    public static func empty(id: String) -> ManifestShard {
        ManifestShard(
            version: 1,
            shardId: id,
            updatedAt: ISO8601.now(),
            files: [:]
        )
    }
}

public enum ISO8601 {
    /// `Date.ISO8601FormatStyle` は値型で Sendable。
    /// UTC + 秒精度（フラクショナル秒なし）で出力する。
    private static let style: Date.ISO8601FormatStyle = .iso8601
        .year().month().day()
        .dateSeparator(.dash)
        .timeSeparator(.colon)
        .time(includingFractionalSeconds: false)
        .timeZone(separator: .omitted)

    public static func now() -> String {
        Date().formatted(style)
    }

    public static func format(_ date: Date) -> String {
        date.formatted(style)
    }

    /// マニフェストの ISO8601 文字列（秒精度・UTC）を Date に戻す。パース不能なら nil。
    /// **format 側に fractional seconds を足さないこと**（CLAUDE.md §7 [mtime 不変条件]）。
    public static func parse(_ s: String) -> Date? {
        try? Date(s, strategy: .iso8601)
    }
}

public enum ManifestJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try enc.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
