import XCTest
import CryptoKit
import TideCore
@testable import Tide

/// `RestoreService.restore` を、フェイクの versionId 対応 S3 シームと実 DB（一時ファイル）+ 一時 syncRoot で
/// 検証する。原パス / 別名退避の分岐・サイズ超過 abort・サイズ不一致・symlink 非追従・versionId 透過を固定する。
final class RestoreServiceTests: XCTestCase {

    // MARK: - env / helpers

    private func makeEnv() throws -> (db: LocalDatabase, root: URL, tmp: URL) {
        let e = try makeTideTestEnv(prefix: "tide-restore-tests")
        return (e.db, e.root, e.tmp)
    }

    private func bytes(_ n: Int, salt: UInt8 = 0) -> Data { TestData.deterministicBytes(n, salt: salt) }

    private func shaHex(_ data: Data) -> String { TestData.shaHex(data) }

    private func service(_ client: any VersionedObjectClient, _ env: (db: LocalDatabase, root: URL, tmp: URL)) -> RestoreService {
        RestoreService(client: client, db: env.db, syncRoot: env.root, tmpDir: env.tmp)
    }

    private func writeLocal(_ env: (db: LocalDatabase, root: URL, tmp: URL), _ rel: String, _ data: Data) throws {
        let url = env.root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func seedFileRecord(_ env: (db: LocalDatabase, root: URL, tmp: URL), _ rel: String, sha: String) async throws {
        try await env.db.pool.write { db in
            var rec = FileRecord(
                path: rel, size: 0, mtime: 0, sha256: sha,
                s3VersionId: nil, s3Etag: nil, lastSyncedAt: 0, updatedAt: 0
            )
            try rec.save(db)
        }
    }

    // MARK: - 原パスへの復元（ローカル不在）

    func testRestoreToOriginalWhenNoLocalFile() async throws {
        let env = try makeEnv()
        let data = bytes(5000)
        let fake = FakeVersionedObjectClient(streamData: data)
        let result = try await service(fake, env).restore(relativePath: "a/b.txt", versionId: "v1")

        XCTAssertFalse(result.diverted)
        XCTAssertEqual(result.writtenRelativePath, "a/b.txt")
        XCTAssertEqual(result.bytes, Int64(data.count))
        XCTAssertEqual(try Data(contentsOf: env.root.appendingPathComponent("a/b.txt")), data)
        XCTAssertEqual(fake.lastVersionId, "v1", "versionId が HEAD / GET に透過される")
    }

    // MARK: - 原パス上書き（ローカルが DB 記録と一致＝未同期編集なし）

    func testRestoreOverwritesOriginalWhenLocalMatchesDB() async throws {
        let env = try makeEnv()
        let current = bytes(1000, salt: 1)         // 現在のローカル（最後に同期した内容）
        let restored = bytes(2000, salt: 2)        // 復元する過去版
        try writeLocal(env, "doc.bin", current)
        try await seedFileRecord(env, "doc.bin", sha: shaHex(current))

        let fake = FakeVersionedObjectClient(streamData: restored)
        let result = try await service(fake, env).restore(relativePath: "doc.bin", versionId: "v9")

        XCTAssertFalse(result.diverted)
        XCTAssertEqual(result.writtenRelativePath, "doc.bin")
        XCTAssertEqual(try Data(contentsOf: env.root.appendingPathComponent("doc.bin")), restored)
    }

    // MARK: - 別名退避（未同期のローカル編集を守る）

    func testRestoreDivertsToCopyWhenLocalUnsyncedEdit() async throws {
        let env = try makeEnv()
        let edited = bytes(1000, salt: 1)          // ユーザが編集した未同期の現在内容
        let lastSynced = bytes(1000, salt: 9)      // 最後に同期した内容（DB 記録）
        let restored = bytes(2000, salt: 2)        // 復元する過去版
        try writeLocal(env, "note.txt", edited)
        try await seedFileRecord(env, "note.txt", sha: shaHex(lastSynced))

        let fake = FakeVersionedObjectClient(streamData: restored)
        let result = try await service(fake, env).restore(relativePath: "note.txt", versionId: "v3")

        XCTAssertTrue(result.diverted)
        XCTAssertNotEqual(result.writtenRelativePath, "note.txt")
        XCTAssertTrue(result.writtenRelativePath.contains("(restored "))
        // 原ファイル（未同期編集）は無傷で保持される。
        XCTAssertEqual(try Data(contentsOf: env.root.appendingPathComponent("note.txt")), edited)
        // 退避コピーに復元内容が入る。
        XCTAssertEqual(try Data(contentsOf: env.root.appendingPathComponent(result.writtenRelativePath)), restored)
    }

    // MARK: - サイズ不一致 / 超過 / 404

    func testSizeMismatchThrowsAndWritesNothing() async throws {
        let env = try makeEnv()
        // HEAD は 200 と申告するが stream は 100 しか返さない → 実サイズ不一致で破棄。
        let fake = FakeVersionedObjectClient(streamData: bytes(100), headSize: 200)
        do {
            _ = try await service(fake, env).restore(relativePath: "x.bin", versionId: "v1")
            XCTFail("サイズ不一致は throw すべき")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.root.appendingPathComponent("x.bin").path))
        // tmp が残らない。
        let leftover = try FileManager.default.contentsOfDirectory(atPath: env.tmp.path)
        XCTAssertTrue(leftover.isEmpty, "tmp は後始末される: \(leftover)")
    }

    func testStreamExceedingExpectedSizeIsAborted() async throws {
        let env = try makeEnv()
        // HEAD は 100 だが stream は 300 返す → 上限超過で abort（DoS ガード）。
        let fake = FakeVersionedObjectClient(streamData: bytes(300), headSize: 100)
        do {
            _ = try await service(fake, env).restore(relativePath: "big.bin", versionId: "v1")
            XCTFail("上限超過は throw すべき")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.root.appendingPathComponent("big.bin").path))
        let leftover = try FileManager.default.contentsOfDirectory(atPath: env.tmp.path)
        XCTAssertTrue(leftover.isEmpty)
    }

    func testHeadNotFoundThrows() async throws {
        let env = try makeEnv()
        let fake = FakeVersionedObjectClient(streamData: bytes(10), notFoundHead: true)
        do {
            _ = try await service(fake, env).restore(relativePath: "gone.bin", versionId: "vX")
            XCTFail("HEAD 404 は throw すべき")
        } catch {}
    }

    // MARK: - symlink 非追従（リンク先実体を上書きしない）

    func testSymlinkAtOriginalIsPreservedAndDivertsToCopy() async throws {
        let env = try makeEnv()
        // 同期ルート外の「秘密」実体と、原パスに置いた symlink。
        let outside = env.root.deletingLastPathComponent().appendingPathComponent("secret.txt")
        try Data("SECRET".utf8).write(to: outside)
        let linkURL = env.root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: outside)

        let restored = bytes(500)
        let fake = FakeVersionedObjectClient(streamData: restored)
        let result = try await service(fake, env).restore(relativePath: "link.txt", versionId: "v1")

        // symlink は読めない（unreadable）扱い → 退避。リンク先実体は無傷。
        XCTAssertTrue(result.diverted)
        XCTAssertEqual(try Data(contentsOf: outside), Data("SECRET".utf8), "リンク先実体を書き換えない")
        // 原パスは依然 symlink のまま。
        let attrs = try FileManager.default.attributesOfItem(atPath: linkURL.path)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink)
        // 退避コピーに復元内容。
        XCTAssertEqual(try Data(contentsOf: env.root.appendingPathComponent(result.writtenRelativePath)), restored)
    }
}

/// `VersionedObjectClient` のフェイク。HEAD のサイズと GET のストリームを別々に指定でき、
/// サイズ不一致 / 超過 / 404 を注入できる。class なので非 Sendable な `sink` をそのまま受けられる。
final class FakeVersionedObjectClient: VersionedObjectClient, @unchecked Sendable {
    let streamData: Data
    let headSize: Int64?
    let notFoundHead: Bool
    let etag: String
    let chunkSize: Int
    private(set) var lastVersionId: String?
    /// GET（stream）が呼ばれた回数。上限ガード等で「DL 前に弾いた」ことの検証用（B-2）。
    private(set) var streamCallCount = 0

    init(streamData: Data, headSize: Int64? = nil, notFoundHead: Bool = false, etag: String = "e1", chunkSize: Int = 1024) {
        self.streamData = streamData
        self.headSize = headSize ?? Int64(streamData.count)
        self.notFoundHead = notFoundHead
        self.etag = etag
        self.chunkSize = chunkSize
    }

    func headObject(key: String, versionId: String?) async throws -> TideS3Client.ObjectHead? {
        lastVersionId = versionId
        if notFoundHead { return nil }
        return TideS3Client.ObjectHead(etag: etag, versionId: versionId, size: headSize, metadata: [:])
    }

    func streamObject(
        key: String,
        versionId: String?,
        rangeStart: Int64?,
        limiter: RateLimiter?,
        sink: (Data) throws -> Void
    ) async throws -> TideS3Client.StreamObjectResult? {
        lastVersionId = versionId
        streamCallCount += 1
        var idx = 0
        while idx < streamData.count {
            let end = min(idx + chunkSize, streamData.count)
            try sink(streamData.subdata(in: idx..<end))
            idx = end
        }
        return TideS3Client.StreamObjectResult(etag: etag, contentLength: Int64(streamData.count))
    }
}
