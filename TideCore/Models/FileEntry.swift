import Foundation

/// マニフェスト (shards/XX.json) の files マップに格納される値。
public struct ManifestFileEntry: Codable, Equatable, Sendable {
    public var size: Int64
    public var mtime: String        // ISO8601 UTC
    public var sha256: String       // hex 小文字
    public var s3VersionId: String?
    public var etag: String
    public var deviceId: String
    public var uploadedAt: String   // ISO8601 UTC

    public init(size: Int64, mtime: String, sha256: String, s3VersionId: String? = nil, etag: String, deviceId: String, uploadedAt: String) {
        self.size = size
        self.mtime = mtime
        self.sha256 = sha256
        self.s3VersionId = s3VersionId
        self.etag = etag
        self.deviceId = deviceId
        self.uploadedAt = uploadedAt
    }

    public enum CodingKeys: String, CodingKey {
        case size
        case mtime
        case sha256
        case s3VersionId = "s3_version_id"
        case etag
        case deviceId = "device_id"
        case uploadedAt = "uploaded_at"
    }
}
