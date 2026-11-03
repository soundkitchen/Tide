import XCTest
import TideCore

/// `ManifestFileEntry` 生成ファクトリ（Issue #118）の契約を固定する。
/// 6 箇所に複製されていたフィールド詰めを集約したので、ここが崩れると全書き手が一斉に乖離する。
final class ManifestFileEntryFactoryTests: XCTestCase {
    private let put = TideS3Client.PutObjectResult(etag: "etag-1", versionId: "v-1")

    func testUploadedMapsEveryFieldAndEncodesDatesAsISO8601() throws {
        let mtime = Date(timeIntervalSince1970: 1_700_000_000)
        let uploadedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let entry = ManifestFileEntry.uploaded(
            size: 42, sha256: "abc", mtime: mtime, put: put, deviceId: "dev-A", uploadedAt: uploadedAt)
        XCTAssertEqual(entry.size, 42)
        XCTAssertEqual(entry.sha256, "abc")
        XCTAssertEqual(entry.s3VersionId, "v-1")
        XCTAssertEqual(entry.etag, "etag-1")
        XCTAssertEqual(entry.deviceId, "dev-A")
        // マニフェスト規約 = ISO8601 UTC 秒精度（fractional seconds なし・[mtime 不変条件]）
        XCTAssertEqual(entry.mtime, "2023-11-14T22:13:20Z")
        XCTAssertEqual(entry.uploadedAt, "2023-11-14T22:15:00Z")
        XCTAssertEqual(entry.mtime, ISO8601.format(mtime))
    }

    func testUploadedDefaultsUploadedAtToNow() throws {
        let before = Date()
        let entry = ManifestFileEntry.uploaded(size: 0, sha256: "x", mtime: before, put: put, deviceId: "d")
        let parsed = try XCTUnwrap(ISO8601.parse(entry.uploadedAt))
        // 秒精度に丸まるので ±2 秒の窓で「今」を確認
        XCTAssertLessThan(abs(parsed.timeIntervalSince(before)), 2)
    }

    func testUploadedPropagatesNilVersionId() {
        let unversioned = TideS3Client.PutObjectResult(etag: "e", versionId: nil)
        let entry = ManifestFileEntry.uploaded(size: 1, sha256: "s", mtime: Date(), put: unversioned, deviceId: "d")
        XCTAssertNil(entry.s3VersionId)
    }

    func testCopiedKeepsContentFieldsAndTakesNewObjectIdentity() {
        let source = ManifestFileEntry(
            size: 7, mtime: "2026-01-02T03:04:05Z", sha256: "sha-src",
            s3VersionId: "v-old", etag: "etag-old", deviceId: "dev-old", uploadedAt: "2026-01-02T03:04:06Z")
        let copy = TideS3Client.PutObjectResult(etag: "etag-new", versionId: "v-new")
        let uploadedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let entry = ManifestFileEntry.copied(from: source, copy: copy, deviceId: "dev-new", uploadedAt: uploadedAt)
        // 内容不変 = size / mtime / sha256 は維持
        XCTAssertEqual(entry.size, 7)
        XCTAssertEqual(entry.mtime, "2026-01-02T03:04:05Z")
        XCTAssertEqual(entry.sha256, "sha-src")
        // オブジェクト識別と書き手は新しい方
        XCTAssertEqual(entry.s3VersionId, "v-new")
        XCTAssertEqual(entry.etag, "etag-new")
        XCTAssertEqual(entry.deviceId, "dev-new")
        XCTAssertEqual(entry.uploadedAt, ISO8601.format(uploadedAt))
    }

    // MARK: - 権限の旗（#162）

    func testUploadedCarriesPermissionsAndCopiedKeepsThem() {
        let perms = ManifestFilePermissions(executable: true, readOnly: true)
        let source = ManifestFileEntry.uploaded(
            size: 1, sha256: "s", mtime: Date(), put: put, deviceId: "d", permissions: perms)
        XCTAssertEqual(source.permissions, perms)
        XCTAssertEqual(
            ManifestFileEntry.uploaded(size: 1, sha256: "s", mtime: Date(), put: put, deviceId: "d").permissions,
            .none)
        let copied = ManifestFileEntry.copied(
            from: source, copy: TideS3Client.PutObjectResult(etag: "e2", versionId: "v-2"), deviceId: "d2")
        XCTAssertEqual(copied.permissions, perms)
    }

    /// JSON: 旗は true のときだけ書く（旗なしの entry は従来と同じ形）・無ければ旗なしとして読む・
    /// `false` を読んでも旗なしと等しい。
    func testPermissionsJSONOmitsFalseAndReadsAbsentAsNone() throws {
        var entry = ManifestFileEntry.uploaded(size: 1, sha256: "s", mtime: Date(), put: put, deviceId: "d")
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any]
        XCTAssertNil(plain?["executable"])
        XCTAssertNil(plain?["read_only"])

        entry.permissions = ManifestFilePermissions(executable: true, readOnly: false)
        let flagged = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any]
        XCTAssertEqual(flagged?["executable"] as? Bool, true)
        XCTAssertNil(flagged?["read_only"])
        XCTAssertEqual(try JSONDecoder().decode(ManifestFileEntry.self, from: JSONEncoder().encode(entry)), entry)

        let legacy = Data("""
            {"size":1,"mtime":"2026-11-03T00:00:00Z","sha256":"s","etag":"e","device_id":"d",\
            "uploaded_at":"2026-11-03T00:00:00Z"}
            """.utf8)
        let legacyEntry = try JSONDecoder().decode(ManifestFileEntry.self, from: legacy)
        XCTAssertEqual(legacyEntry.permissions, .none)

        let explicitFalse = Data("""
            {"size":1,"mtime":"2026-11-03T00:00:00Z","sha256":"s","etag":"e","device_id":"d",\
            "uploaded_at":"2026-11-03T00:00:00Z","executable":false,"read_only":false}
            """.utf8)
        XCTAssertEqual(try JSONDecoder().decode(ManifestFileEntry.self, from: explicitFalse), legacyEntry)
    }
}
