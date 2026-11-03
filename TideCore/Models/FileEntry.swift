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
    /// 実行できる（#162・`chmod +x`）。**true のときだけ書く**（false は nil に揃える）— 無い = 実行できない
    /// なので、旗を持たない既存の entry もそのまま読める。直接触らず `permissions` を使う。
    public private(set) var executable: Bool?
    /// 読み取り専用（#162・`chmod 444` など = ユーザの書き込みが無い）。書き方は `executable` と同じ。
    public private(set) var readOnly: Bool?

    public init(
        size: Int64, mtime: String, sha256: String, s3VersionId: String? = nil, etag: String,
        deviceId: String, uploadedAt: String, permissions: ManifestFilePermissions = .none
    ) {
        self.size = size
        self.mtime = mtime
        self.sha256 = sha256
        self.s3VersionId = s3VersionId
        self.etag = etag
        self.deviceId = deviceId
        self.uploadedAt = uploadedAt
        self.permissions = permissions
    }

    /// 読み込みでも false を nil に揃える（ほかの書き手が `false` を書いても、旗の無い entry と等しくなる）。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            size: try c.decode(Int64.self, forKey: .size),
            mtime: try c.decode(String.self, forKey: .mtime),
            sha256: try c.decode(String.self, forKey: .sha256),
            s3VersionId: try c.decodeIfPresent(String.self, forKey: .s3VersionId),
            etag: try c.decode(String.self, forKey: .etag),
            deviceId: try c.decode(String.self, forKey: .deviceId),
            uploadedAt: try c.decode(String.self, forKey: .uploadedAt),
            permissions: ManifestFilePermissions(
                executable: try c.decodeIfPresent(Bool.self, forKey: .executable) ?? false,
                readOnly: try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false))
    }

    /// 実行・読み取り専用の旗（#162）。設定すると false を nil に揃える（JSON に書かない）。
    public var permissions: ManifestFilePermissions {
        get { ManifestFilePermissions(executable: executable == true, readOnly: readOnly == true) }
        set {
            executable = newValue.executable ? true : nil
            readOnly = newValue.readOnly ? true : nil
        }
    }

    public enum CodingKeys: String, CodingKey {
        case size
        case mtime
        case sha256
        case s3VersionId = "s3_version_id"
        case etag
        case deviceId = "device_id"
        case uploadedAt = "uploaded_at"
        case executable
        case readOnly = "read_only"
    }
}

/// マニフェストの file entry が持つ権限の旗（#162）。File Provider が扱えるのはユーザの分だけなので、
/// 実行と読み取り専用の 2 つだけを持つ（読み取りは常にできる）。
public struct ManifestFilePermissions: Equatable, Sendable {
    public var executable: Bool
    public var readOnly: Bool

    public init(executable: Bool, readOnly: Bool) {
        self.executable = executable
        self.readOnly = readOnly
    }

    /// 旗なし = 読み書きでき、実行できない（旗を持たない既存の entry と同じ）。
    public static let none = ManifestFilePermissions(executable: false, readOnly: false)
}
