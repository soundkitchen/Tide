import Foundation

/// マニフェスト (shards/XX.json) の files マップに格納される値。
struct ManifestFileEntry: Codable, Equatable, Sendable {
    var size: Int64
    var mtime: String        // ISO8601 UTC
    var sha256: String       // hex 小文字
    var s3VersionId: String?
    var etag: String
    var deviceId: String
    var uploadedAt: String   // ISO8601 UTC

    enum CodingKeys: String, CodingKey {
        case size
        case mtime
        case sha256
        case s3VersionId = "s3_version_id"
        case etag
        case deviceId = "device_id"
        case uploadedAt = "uploaded_at"
    }
}
