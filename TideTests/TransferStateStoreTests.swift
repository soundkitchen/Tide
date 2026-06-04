import XCTest
@testable import Tide

/// `transfer_state` テーブルと `TransferStateStore` の永続化挙動を実 DB（一時ファイル）で検証する。
final class TransferStateStoreTests: XCTestCase {
    private func makeStore() throws -> TransferStateStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tide-ts-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let db = try LocalDatabase(at: dir.appendingPathComponent("db.sqlite"))
        return TransferStateStore(db: db)
    }

    // MARK: - アップロード

    func testUploadLifecycle() async throws {
        let store = try makeStore()
        let path = "dir/big.bin"

        // 何も無い状態では nil。
        let none = try await store.loadUpload(path: path)
        XCTAssertNil(none)

        try await store.beginUpload(
            path: path, uploadId: "up-123", partSize: 8 * 1024 * 1024,
            fileMtime: 1700.5, fileSize: 123_456_789
        )

        let begun = try await store.loadUpload(path: path)
        XCTAssertEqual(begun?.uploadId, "up-123")
        XCTAssertEqual(begun?.partSize, 8 * 1024 * 1024)
        XCTAssertEqual(begun?.fileMtime, 1700.5)
        XCTAssertEqual(begun?.fileSize, 123_456_789)
        XCTAssertEqual(begun?.completedParts, [])

        // パート完了を順次記録（順序が保持される）。
        try await store.recordCompletedPart(path: path, part: CompletedPart(n: 1, etag: "e1"))
        try await store.recordCompletedPart(path: path, part: CompletedPart(n: 2, etag: "e2"))
        try await store.recordCompletedPart(path: path, part: CompletedPart(n: 3, etag: "e3"))

        let withParts = try await store.loadUpload(path: path)
        XCTAssertEqual(withParts?.completedParts, [
            CompletedPart(n: 1, etag: "e1"),
            CompletedPart(n: 2, etag: "e2"),
            CompletedPart(n: 3, etag: "e3"),
        ])

        // 同一パート番号の再記録は冪等（重複しない）。
        try await store.recordCompletedPart(path: path, part: CompletedPart(n: 2, etag: "e2-again"))
        let afterDup = try await store.loadUpload(path: path)
        XCTAssertEqual(afterDup?.completedParts.count, 3)
        XCTAssertEqual(afterDup?.completedParts.first(where: { $0.n == 2 })?.etag, "e2")

        // clear で消える。
        try await store.clearUpload(path: path)
        let cleared = try await store.loadUpload(path: path)
        XCTAssertNil(cleared)
    }

    func testBeginUploadReplacesStaleSession() async throws {
        let store = try makeStore()
        let path = "a.bin"

        try await store.beginUpload(path: path, uploadId: "old", partSize: 1024, fileMtime: 1, fileSize: 10)
        try await store.recordCompletedPart(path: path, part: CompletedPart(n: 1, etag: "old-e1"))

        // 同じ path で begin し直すと旧 UploadId・旧完了パートは破棄される。
        try await store.beginUpload(path: path, uploadId: "new", partSize: 2048, fileMtime: 2, fileSize: 20)
        let state = try await store.loadUpload(path: path)
        XCTAssertEqual(state?.uploadId, "new")
        XCTAssertEqual(state?.partSize, 2048)
        XCTAssertEqual(state?.completedParts, [])
    }

    func testRecordCompletedPartOnMissingRowIsNoop() async throws {
        let store = try makeStore()
        // begin されていない path への記録は throw せず何もしない。
        try await store.recordCompletedPart(path: "ghost.bin", part: CompletedPart(n: 1, etag: "x"))
        let state = try await store.loadUpload(path: "ghost.bin")
        XCTAssertNil(state)
    }

    // MARK: - ダウンロード

    func testDownloadLifecycle() async throws {
        let store = try makeStore()
        let path = "video/clip.mov"

        let none = try await store.loadDownload(path: path)
        XCTAssertNil(none)

        try await store.beginDownload(path: path, tmpPath: "/tmp/tide/clip.part", expectedEtag: "etag-abc")
        let begun = try await store.loadDownload(path: path)
        XCTAssertEqual(begun?.tmpPath, "/tmp/tide/clip.part")
        XCTAssertEqual(begun?.bytesDone, 0)
        XCTAssertEqual(begun?.expectedEtag, "etag-abc")

        try await store.recordDownloadProgress(path: path, bytesDone: 5_000_000)
        let after1 = try await store.loadDownload(path: path)
        XCTAssertEqual(after1?.bytesDone, 5_000_000)

        try await store.recordDownloadProgress(path: path, bytesDone: 9_999_999)
        let after2 = try await store.loadDownload(path: path)
        XCTAssertEqual(after2?.bytesDone, 9_999_999)

        try await store.clearDownload(path: path)
        let cleared = try await store.loadDownload(path: path)
        XCTAssertNil(cleared)
    }

    // MARK: - 方向の独立性 / 全行

    func testUploadAndDownloadAreIndependentForSamePath() async throws {
        let store = try makeStore()
        let path = "shared.bin"

        try await store.beginUpload(path: path, uploadId: "u", partSize: 1024, fileMtime: 1, fileSize: 10)
        try await store.beginDownload(path: path, tmpPath: "/tmp/shared.part", expectedEtag: nil)

        // upload を clear しても download 行は残る（PK が (path, direction) で独立）。
        try await store.clearUpload(path: path)
        let upload = try await store.loadUpload(path: path)
        let download = try await store.loadDownload(path: path)
        XCTAssertNil(upload)
        XCTAssertNotNil(download)
    }

    func testAllEntriesReturnsEveryRow() async throws {
        let store = try makeStore()
        try await store.beginUpload(path: "u.bin", uploadId: "u", partSize: 1024, fileMtime: 1, fileSize: 10)
        try await store.beginDownload(path: "d.bin", tmpPath: "/tmp/d.part", expectedEtag: "e")

        let all = try await store.allEntries()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(Set(all.map { $0.direction }), ["upload", "download"])
        XCTAssertEqual(all.first(where: { $0.direction == "upload" })?.path, "u.bin")
        XCTAssertEqual(all.first(where: { $0.direction == "download" })?.tmpPath, "/tmp/d.part")
    }
}
