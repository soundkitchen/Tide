import XCTest
@testable import Tide

/// `LocalDatabase.refreshMtimeIfShaUnchanged`（SHA ゲートの CAS 更新）の回帰テスト。
/// 判定（read → hash）と書込の間に並行 pull が同 path を更新した場合に、
/// 新しい sha / s3VersionId / s3Etag を巻き戻さないことを固定する。
final class LocalDatabaseTests: XCTestCase {
    private func makeDB() throws -> LocalDatabase {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("tide-db-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return try LocalDatabase(at: base.appendingPathComponent("db.sqlite"))
    }

    private func seed(
        _ db: LocalDatabase, path: String, mtime: Double, sha: String,
        versionId: String? = "v1", lastSyncedAt: Double? = 1_780_000_000
    ) async throws {
        try await db.pool.write { dbq in
            var rec = FileRecord(
                path: path, size: 100, mtime: mtime, sha256: sha,
                s3VersionId: versionId, s3Etag: "e1",
                lastSyncedAt: lastSyncedAt, updatedAt: 1_780_000_000
            )
            try rec.save(dbq)
        }
    }

    private func fetch(_ db: LocalDatabase, _ path: String) async throws -> FileRecord? {
        try await db.pool.read { dbq in try FileRecord.fetchOne(dbq, key: path) }
    }

    func testRefreshUpdatesMtimeAndPreservesEverythingElse() async throws {
        let db = try makeDB()
        try await seed(db, path: "a.bin", mtime: 1_780_000_000.0, sha: "abc")

        let updated = try await db.refreshMtimeIfShaUnchanged(
            path: "a.bin", expectedSha: "abc", newMtime: 1_780_000_000.789
        )

        XCTAssertTrue(updated)
        let fetched = try await fetch(db, "a.bin")
        let rec = try XCTUnwrap(fetched)
        XCTAssertEqual(rec.mtime, 1_780_000_000.789, accuracy: 0.0001)
        XCTAssertEqual(rec.sha256, "abc")
        XCTAssertEqual(rec.s3VersionId, "v1", "sha/versionId は触らない")
        XCTAssertEqual(rec.lastSyncedAt, 1_780_000_000, "lastSyncedAt を保持（tracked 判定が崩れない）")
    }

    func testRefreshIsNoopWhenShaChangedConcurrently() async throws {
        let db = try makeDB()
        // 判定時 sha = "abc" → 書込前に並行 pull が新内容（sha = "new", v2, 新 mtime）で更新した状況。
        try await seed(db, path: "a.bin", mtime: 1_790_000_000.0, sha: "new", versionId: "v2")

        let updated = try await db.refreshMtimeIfShaUnchanged(
            path: "a.bin", expectedSha: "abc", newMtime: 1_780_000_000.789
        )

        XCTAssertFalse(updated, "sha 不一致なら no-op（並行更新を巻き戻さない）")
        let fetched = try await fetch(db, "a.bin")
        let rec = try XCTUnwrap(fetched)
        XCTAssertEqual(rec.mtime, 1_790_000_000.0, accuracy: 0.0001)
        XCTAssertEqual(rec.sha256, "new")
        XCTAssertEqual(rec.s3VersionId, "v2")
    }

    func testRefreshIsNoopWhenRowMissing() async throws {
        let db = try makeDB()
        let updated = try await db.refreshMtimeIfShaUnchanged(
            path: "ghost.bin", expectedSha: "abc", newMtime: 1
        )
        XCTAssertFalse(updated)
    }
}
