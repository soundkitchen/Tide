import XCTest
import TideCore
@testable import Tide

final class DeletedFilesCacheTests: XCTestCase {

    private func sampleHistory(_ path: String) -> FileVersionHistory {
        FileVersionHistory(relativePath: path, versions: [
            FileVersion(versionId: "v-del", size: nil,
                        lastModified: Date(timeIntervalSince1970: 1_700_000_100),
                        etag: nil, isLatest: true, isDeleteMarker: true),
            FileVersion(versionId: "v-live", size: 1234,
                        lastModified: Date(timeIntervalSince1970: 1_700_000_000),
                        etag: "abc", isLatest: false, isDeleteMarker: false),
        ])
    }

    private func samplePayload(schemaVersion: Int = DeletedFilesCache.currentSchemaVersion,
                               bucket: String = "my-bucket") -> DeletedFilesCache.Payload {
        DeletedFilesCache.Payload(
            schemaVersion: schemaVersion,
            bucket: bucket,
            updatedAt: Date(timeIntervalSince1970: 1_700_001_000),
            files: [sampleHistory("docs/a.txt"), sampleHistory("b.bin")]
        )
    }

    func testEncodeDecodeRoundTrip() throws {
        let payload = samplePayload()
        let data = try DeletedFilesCache.encode(payload)
        let decoded = try DeletedFilesCache.decode(data)
        XCTAssertEqual(decoded, payload)
        // 復元に要る情報（delete marker 直前の実体版）が往復で保たれている。
        XCTAssertEqual(decoded.files.first?.latestRestorableVersion?.versionId, "v-live")
        XCTAssertTrue(decoded.files.first?.isDeleted ?? false)
    }

    func testDecodeRejectsWrongSchemaVersion() throws {
        let future = samplePayload(schemaVersion: DeletedFilesCache.currentSchemaVersion + 1)
        let data = try DeletedFilesCache.encode(future)
        XCTAssertThrowsError(try DeletedFilesCache.decode(data)) { error in
            guard case DeletedFilesCache.CacheError.unsupportedVersion = error else {
                return XCTFail("Expected unsupportedVersion, got \(error)")
            }
        }
    }

    func testDecodeRejectsGarbage() {
        let garbage = Data("not a cache".utf8)
        XCTAssertThrowsError(try DeletedFilesCache.decode(garbage))
    }

    func testValidateBucketMatch() {
        let payload = samplePayload(bucket: "my-bucket")
        XCTAssertEqual(DeletedFilesCache.validate(payload, bucket: "my-bucket"), payload)
    }

    func testValidateBucketMismatchReturnsNil() {
        let payload = samplePayload(bucket: "my-bucket")
        XCTAssertNil(DeletedFilesCache.validate(payload, bucket: "other-bucket"))
    }
}
