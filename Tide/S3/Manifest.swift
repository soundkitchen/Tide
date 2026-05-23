import Foundation

struct ManifestIndex: Codable, Equatable, Sendable {
    var version: Int = 1
    var updatedAt: String       // ISO8601 UTC
    var updatedBy: String       // device id
    var shards: [String: ShardInfo]

    struct ShardInfo: Codable, Equatable, Sendable {
        var etag: String
        var count: Int
    }

    enum CodingKeys: String, CodingKey {
        case version
        case updatedAt = "updated_at"
        case updatedBy = "updated_by"
        case shards
    }

    static func empty(updatedBy deviceId: String) -> ManifestIndex {
        ManifestIndex(
            version: 1,
            updatedAt: ISO8601.now(),
            updatedBy: deviceId,
            shards: [:]
        )
    }
}

struct ManifestShard: Codable, Equatable, Sendable {
    var version: Int = 1
    var shardId: String
    var updatedAt: String
    var files: [String: ManifestFileEntry]

    enum CodingKeys: String, CodingKey {
        case version
        case shardId = "shard_id"
        case updatedAt = "updated_at"
        case files
    }

    static func empty(id: String) -> ManifestShard {
        ManifestShard(
            version: 1,
            shardId: id,
            updatedAt: ISO8601.now(),
            files: [:]
        )
    }
}

enum ISO8601 {
    /// `Date.ISO8601FormatStyle` は値型で Sendable。
    /// UTC + 秒精度（フラクショナル秒なし）で出力する。
    private static let style: Date.ISO8601FormatStyle = .iso8601
        .year().month().day()
        .dateSeparator(.dash)
        .timeSeparator(.colon)
        .time(includingFractionalSeconds: false)
        .timeZone(separator: .omitted)

    static func now() -> String {
        Date().formatted(style)
    }

    static func format(_ date: Date) -> String {
        date.formatted(style)
    }
}

enum ManifestJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try enc.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
