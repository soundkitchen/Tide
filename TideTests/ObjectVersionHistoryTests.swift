import XCTest
import TideCore
@testable import Tide

final class ObjectVersionHistoryTests: XCTestCase {

    // MARK: - builders

    private func ver(
        _ key: String, _ vid: String, t: Double?, size: Int64 = 10, latest: Bool = false
    ) -> TideS3Client.S3ObjectVersionRaw {
        .init(
            key: key, versionId: vid, isLatest: latest, size: size,
            lastModified: t.map { Date(timeIntervalSince1970: $0) }, etag: "e-\(vid)"
        )
    }

    private func marker(
        _ key: String, _ vid: String, t: Double?, latest: Bool = false
    ) -> TideS3Client.S3DeleteMarkerRaw {
        .init(
            key: key, versionId: vid, isLatest: latest,
            lastModified: t.map { Date(timeIntervalSince1970: $0) }
        )
    }

    // MARK: - relativePath 正規化（不正キー除外）

    func testRelativePathStripsFilesPrefix() {
        XCTAssertEqual(ObjectVersionHistory.relativePath(fromKey: "files/a/b.txt"), "a/b.txt")
        XCTAssertEqual(ObjectVersionHistory.relativePath(fromKey: "files/note.txt"), "note.txt")
    }

    func testRelativePathRejectsInvalidKeys() {
        // プレフィックス不一致
        XCTAssertNil(ObjectVersionHistory.relativePath(fromKey: "other/x"))
        XCTAssertNil(ObjectVersionHistory.relativePath(fromKey: ".tide/index.json"))
        // 剥がすと空
        XCTAssertNil(ObjectVersionHistory.relativePath(fromKey: "files/"))
        // PathValidator 不合格（`..` / 絶対パス）
        XCTAssertNil(ObjectVersionHistory.relativePath(fromKey: "files/../secret"))
        XCTAssertNil(ObjectVersionHistory.relativePath(fromKey: "files/a/../b"))
    }

    func testRelativePathCustomPrefix() {
        XCTAssertEqual(ObjectVersionHistory.relativePath(fromKey: "p/x.txt", keyPrefix: "p/"), "x.txt")
    }

    // MARK: - グルーピング / 時系列降順

    func testGroupOrdersVersionsNewestFirst() {
        let vs = [
            ver("files/doc.txt", "v1", t: 100),
            ver("files/doc.txt", "v3", t: 300, latest: true),
            ver("files/doc.txt", "v2", t: 200),
        ]
        let h = ObjectVersionHistory.group(versions: vs, deleteMarkers: [])
        XCTAssertEqual(h.count, 1)
        XCTAssertEqual(h[0].relativePath, "doc.txt")
        XCTAssertEqual(h[0].versions.map(\.versionId), ["v3", "v2", "v1"])
        XCTAssertFalse(h[0].isDeleted)
        XCTAssertEqual(h[0].latestRestorableVersion?.versionId, "v3")
    }

    func testGroupSortsPathsAscendingAndExcludesInvalidKeys() {
        let vs = [
            ver("files/b.txt", "vb", t: 100),
            ver("files/a.txt", "va", t: 100),
            ver("files/../escape", "vbad", t: 100),  // 除外される
            ver("nope/x", "vnope", t: 100),           // 除外される
        ]
        let h = ObjectVersionHistory.group(versions: vs, deleteMarkers: [])
        XCTAssertEqual(h.map(\.relativePath), ["a.txt", "b.txt"])
    }

    func testEmptyInputYieldsEmpty() {
        XCTAssertTrue(ObjectVersionHistory.group(versions: [], deleteMarkers: []).isEmpty)
    }

    // MARK: - delete marker 判定

    func testDeletedFileHasMarkerLatestAndRestorablePriorVersion() {
        let vs = [ver("files/doc.txt", "v1", t: 100)]
        let ms = [marker("files/doc.txt", "m1", t: 200, latest: true)]
        let h = ObjectVersionHistory.group(versions: vs, deleteMarkers: ms)
        XCTAssertEqual(h.count, 1)
        XCTAssertEqual(h[0].versions.map(\.versionId), ["m1", "v1"])
        XCTAssertTrue(h[0].versions[0].isDeleteMarker)
        XCTAssertTrue(h[0].isDeleted)
        XCTAssertEqual(h[0].latestRestorableVersion?.versionId, "v1")
    }

    func testRecreatedAfterDeleteIsNotDeleted() {
        // 削除 → 再作成（marker より新しい実体版）→ 現存扱い
        let vs = [
            ver("files/doc.txt", "v1", t: 100),
            ver("files/doc.txt", "v3", t: 300, latest: true),
        ]
        let ms = [marker("files/doc.txt", "m2", t: 200)]
        let h = ObjectVersionHistory.group(versions: vs, deleteMarkers: ms)
        XCTAssertEqual(h[0].versions.map(\.versionId), ["v3", "m2", "v1"])
        XCTAssertFalse(h[0].isDeleted)
        XCTAssertEqual(h[0].latestRestorableVersion?.versionId, "v3")
    }

    // MARK: - deletedFiles フィルタ

    func testDeletedFilesIncludesOnlyDeletedWithRestorableVersion() {
        // 削除済み + 復元可能
        let deleted = ObjectVersionHistory.group(
            versions: [ver("files/a.txt", "v1", t: 100)],
            deleteMarkers: [marker("files/a.txt", "m1", t: 200, latest: true)]
        )
        XCTAssertEqual(ObjectVersionHistory.deletedFiles(deleted).map(\.relativePath), ["a.txt"])

        // 現存（削除されていない）→ 除外
        let live = ObjectVersionHistory.group(
            versions: [ver("files/b.txt", "v1", t: 100, latest: true)], deleteMarkers: []
        )
        XCTAssertTrue(ObjectVersionHistory.deletedFiles(live).isEmpty)

        // delete marker のみ（復元先が無い）→ 除外
        let markerOnly = ObjectVersionHistory.group(
            versions: [], deleteMarkers: [marker("files/c.txt", "m1", t: 100, latest: true)]
        )
        XCTAssertTrue(markerOnly[0].isDeleted)
        XCTAssertNil(markerOnly[0].latestRestorableVersion)
        XCTAssertTrue(ObjectVersionHistory.deletedFiles(markerOnly).isEmpty)
    }

    // MARK: - 並び順の tie-break / nil 時刻

    func testTieBreakPutsLatestFirstOnEqualTimestamp() {
        let vs = [
            ver("files/doc.txt", "vA", t: 100, latest: false),
            ver("files/doc.txt", "vB", t: 100, latest: true),
        ]
        let h = ObjectVersionHistory.group(versions: vs, deleteMarkers: [])
        XCTAssertEqual(h[0].versions.first?.versionId, "vB")
    }

    func testNilLastModifiedSortsLast() {
        let vs = [
            ver("files/doc.txt", "vNil", t: nil),
            ver("files/doc.txt", "vDated", t: 100),
        ]
        let h = ObjectVersionHistory.group(versions: vs, deleteMarkers: [])
        XCTAssertEqual(h[0].versions.map(\.versionId), ["vDated", "vNil"])
    }
}
