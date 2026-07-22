import XCTest
import CryptoKit
import TideCore
@testable import Tide

/// `S3RestoreService.restore`（M5 Track B-2 = fpOnly の S3 内復元）を、フェイクの
/// DL / PUT シームと `InMemoryManifestStore` で検証する。
/// 「tmp DL → 現行版 PUT → `ManifestUpdater` 合流」の配線・no-op 短絡・競合中断・
/// サイズガード・tmp 後始末・signal 発火を固定する。
final class S3RestoreServiceTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tide-s3restore-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - helpers

    private func bytes(_ n: Int, salt: UInt8 = 0) -> Data { TestData.deterministicBytes(n, salt: salt) }
    private func shaHex(_ data: Data) -> String { TestData.shaHex(data) }

    private func makeService(
        stream: FakeVersionedObjectClient,
        put: FakeRestorePutClient,
        store: InMemoryManifestStore,
        counter: SignalCounter,
        uploadSizeLimitBytes: Int64 = 0
    ) -> S3RestoreService {
        S3RestoreService(
            client: stream,
            put: put,
            updater: ManifestUpdater(
                store: store,
                deviceId: "test-device",
                onManifestDidWrite: { counter.fire() }
            ),
            tmpDir: tmpDir,
            uploadSizeLimitBytes: uploadSizeLimitBytes
        )
    }

    private func seedEntry(
        _ store: InMemoryManifestStore, path: String, sha: String
    ) async {
        let shardId = ManifestSharding.shardId(for: path)
        await store.seed(shard: ManifestShard(
            shardId: shardId,
            updatedAt: "2026-07-01T00:00:00Z",
            files: [path: makeManifestEntry(sha: sha)]
        ))
    }

    private func assertTmpEmpty(file: StaticString = #filePath, line: UInt = #line) throws {
        let leftover = try FileManager.default.contentsOfDirectory(atPath: tmpDir.path)
        XCTAssertTrue(leftover.isEmpty, "tmp は後始末される: \(leftover)", file: file, line: line)
    }

    // MARK: - 復元 = 新しい現行版として書く

    func testRestoreWritesNewCurrentVersionAndSignals() async throws {
        let path = "docs/note.txt"
        let old = bytes(5000, salt: 7)  // 復元する過去版の内容
        let store = InMemoryManifestStore()
        await seedEntry(store, path: path, sha: "current-sha")  // 現行は別内容

        let stream = FakeVersionedObjectClient(streamData: old)
        let put = FakeRestorePutClient()
        let counter = SignalCounter()
        let outcome = try await makeService(stream: stream, put: put, store: store, counter: counter)
            .restore(relativePath: path, versionId: "v-old")

        XCTAssertEqual(outcome, .restored)
        XCTAssertEqual(stream.lastVersionId, "v-old", "versionId が HEAD / GET に透過される")
        XCTAssertEqual(put.putCalls.count, 1)
        XCTAssertEqual(put.putCalls[0].key, "files/\(path)")
        XCTAssertEqual(put.putCalls[0].data, old, "DL した過去版そのものを PUT する")
        // マニフェストが新 entry へ更新される（共有チョークポイント合流）。
        let entry = await store.shards[ManifestSharding.shardId(for: path)]?.files[path]
        XCTAssertEqual(entry?.sha256, shaHex(old))
        XCTAssertEqual(entry?.size, Int64(old.count))
        XCTAssertEqual(entry?.s3VersionId, put.versionId, "identity は PUT 結果から取る")
        XCTAssertEqual(entry?.etag, put.etag)
        XCTAssertEqual(entry?.deviceId, "test-device", "deviceId は updater と同一の正本")
        XCTAssertEqual(counter.count, 1, "書込確定点で signal が 1 回発火する")
        try assertTmpEmpty()
    }

    /// 削除済みファイル（現行 entry なし）は base nil の新規作成側で合流する。
    func testRestoreDeletedFileCreatesEntry() async throws {
        let path = "gone/file.bin"
        let old = bytes(3000, salt: 3)
        let store = InMemoryManifestStore()  // entry なし = 現在削除済み

        let stream = FakeVersionedObjectClient(streamData: old)
        let put = FakeRestorePutClient()
        let counter = SignalCounter()
        let outcome = try await makeService(stream: stream, put: put, store: store, counter: counter)
            .restore(relativePath: path, versionId: "v-old")

        XCTAssertEqual(outcome, .restored)
        let entry = await store.shards[ManifestSharding.shardId(for: path)]?.files[path]
        XCTAssertEqual(entry?.sha256, shaHex(old))
        XCTAssertEqual(counter.count, 1)
        try assertTmpEmpty()
    }

    // MARK: - no-op 短絡（現行と同一内容）

    func testAlreadyCurrentSkipsPutAndManifestWrite() async throws {
        let path = "same.txt"
        let content = bytes(2000, salt: 1)
        let store = InMemoryManifestStore()
        await seedEntry(store, path: path, sha: shaHex(content))  // 現行 == 復元対象

        let stream = FakeVersionedObjectClient(streamData: content)
        let put = FakeRestorePutClient()
        let counter = SignalCounter()
        let outcome = try await makeService(stream: stream, put: put, store: store, counter: counter)
            .restore(relativePath: path, versionId: "v-old")

        XCTAssertEqual(outcome, .alreadyCurrent)
        XCTAssertTrue(put.putCalls.isEmpty, "同一内容は PUT しない（版チャーン防止）")
        XCTAssertEqual(counter.count, 0, "マニフェスト無書込 = signal も発火しない")
        try assertTmpEmpty()
    }

    // MARK: - 並行更新の競合（uploadConflict で安全中断）

    func testConcurrentManifestChangeAbortsWithUploadConflict() async throws {
        let path = "raced.txt"
        let old = bytes(1000, salt: 2)
        let store = InMemoryManifestStore()
        await seedEntry(store, path: path, sha: "base-sha")

        let stream = FakeVersionedObjectClient(streamData: old)
        let put = FakeRestorePutClient()
        // ベース読み取り（サービス冒頭）の後・マニフェスト RMW の前に、並行書き手が entry を
        // 進めた状況を PUT 直後フックで注入する（@Sendable のため self 非キャプチャで直接 seed）。
        put.onPut = {
            await store.seed(shard: ManifestShard(
                shardId: ManifestSharding.shardId(for: path),
                updatedAt: "2026-07-02T00:00:00Z",
                files: [path: makeManifestEntry(sha: "racer-sha")]
            ))
        }
        let counter = SignalCounter()
        do {
            _ = try await makeService(stream: stream, put: put, store: store, counter: counter)
                .restore(relativePath: path, versionId: "v-old")
            XCTFail("並行更新は uploadConflict で中断すべき")
        } catch let e as SyncError {
            guard case .uploadConflict = e else {
                return XCTFail("uploadConflict であるべき: \(e)")
            }
        }
        // 並行書き手の entry を上書きしない（無音上書きなし）。
        let entry = await store.shards[ManifestSharding.shardId(for: path)]?.files[path]
        XCTAssertEqual(entry?.sha256, "racer-sha")
        XCTAssertEqual(counter.count, 0)
        try assertTmpEmpty()
    }

    // MARK: - サイズガード

    func testSizeMismatchAbortsBeforePut() async throws {
        // HEAD は 200 と申告するが stream は 100 しか返さない → 実サイズ不一致で破棄。
        let store = InMemoryManifestStore()
        let stream = FakeVersionedObjectClient(streamData: bytes(100), headSize: 200)
        let put = FakeRestorePutClient()
        let counter = SignalCounter()
        do {
            _ = try await makeService(stream: stream, put: put, store: store, counter: counter)
                .restore(relativePath: "x.bin", versionId: "v1")
            XCTFail("サイズ不一致は throw すべき")
        } catch {}
        XCTAssertTrue(put.putCalls.isEmpty)
        XCTAssertEqual(counter.count, 0)
        try assertTmpEmpty()
    }

    func testStreamExceedingExpectedSizeIsAborted() async throws {
        // HEAD は 100 だが stream は 300 返す → 上限超過で即破棄（DoS ガード）。
        let store = InMemoryManifestStore()
        let stream = FakeVersionedObjectClient(streamData: bytes(300), headSize: 100)
        let put = FakeRestorePutClient()
        let counter = SignalCounter()
        do {
            _ = try await makeService(stream: stream, put: put, store: store, counter: counter)
                .restore(relativePath: "big.bin", versionId: "v1")
            XCTFail("上限超過は throw すべき")
        } catch {}
        XCTAssertTrue(put.putCalls.isEmpty)
        try assertTmpEmpty()
    }

    /// 復元は再アップロードを伴うため、アップロード上限を DL 前に適用する。
    func testUploadSizeLimitRejectsBeforeDownload() async throws {
        let store = InMemoryManifestStore()
        let stream = FakeVersionedObjectClient(streamData: bytes(200), headSize: 200)
        let put = FakeRestorePutClient()
        let counter = SignalCounter()
        do {
            _ = try await makeService(
                stream: stream, put: put, store: store, counter: counter, uploadSizeLimitBytes: 100
            ).restore(relativePath: "huge.bin", versionId: "v1")
            XCTFail("上限超過は fileTooLarge で弾くべき")
        } catch let e as SyncError {
            guard case .fileTooLarge = e else {
                return XCTFail("fileTooLarge であるべき: \(e)")
            }
        }
        XCTAssertEqual(stream.streamCallCount, 0, "DL 前（HEAD 直後）に弾く")
        XCTAssertTrue(put.putCalls.isEmpty)
        try assertTmpEmpty()
    }

    // MARK: - 入口検証

    func testInvalidRelativePathIsRejected() async throws {
        let store = InMemoryManifestStore()
        let stream = FakeVersionedObjectClient(streamData: bytes(10))
        let put = FakeRestorePutClient()
        let counter = SignalCounter()
        do {
            _ = try await makeService(stream: stream, put: put, store: store, counter: counter)
                .restore(relativePath: "../evil.txt", versionId: "v1")
            XCTFail("不正パスは入口で拒否すべき")
        } catch {}
        XCTAssertEqual(stream.streamCallCount, 0)
        XCTAssertTrue(put.putCalls.isEmpty)
    }

    func testHeadNotFoundThrows() async throws {
        let store = InMemoryManifestStore()
        let stream = FakeVersionedObjectClient(streamData: bytes(10), notFoundHead: true)
        let put = FakeRestorePutClient()
        let counter = SignalCounter()
        do {
            _ = try await makeService(stream: stream, put: put, store: store, counter: counter)
                .restore(relativePath: "gone.bin", versionId: "vX")
            XCTFail("HEAD 404 は throw すべき")
        } catch {}
        XCTAssertTrue(put.putCalls.isEmpty)
    }

    // MARK: - マルチパート経路（16 MiB 超）

    func testMultipartUsedOverThreshold() async throws {
        let path = "big/video.mov"
        let size = Int(PartPlan.multipartThreshold) + 1024
        let old = bytes(size, salt: 5)
        let store = InMemoryManifestStore()
        await seedEntry(store, path: path, sha: "current-sha")

        let stream = FakeVersionedObjectClient(streamData: old, chunkSize: 1 << 20)
        let put = FakeRestorePutClient()
        let counter = SignalCounter()
        let outcome = try await makeService(stream: stream, put: put, store: store, counter: counter)
            .restore(relativePath: path, versionId: "v-old")

        XCTAssertEqual(outcome, .restored)
        XCTAssertEqual(put.putCalls.count, 1)
        XCTAssertTrue(put.putCalls[0].viaMultipart, "閾値超えはマルチパートで上げる")
        XCTAssertEqual(put.putCalls[0].data, old, "パート結合結果が過去版と一致する")
        let entry = await store.shards[ManifestSharding.shardId(for: path)]?.files[path]
        XCTAssertEqual(entry?.sha256, shaHex(old))
        XCTAssertEqual(entry?.size, Int64(size))
        XCTAssertEqual(counter.count, 1)
        try assertTmpEmpty()
    }
}

/// `RestorePutClient` のフェイク。単発 PUT とマルチパートの両方を記録し、
/// PUT 直後フック（`onPut`）で「本体 PUT とマニフェスト RMW の間」への競合注入ができる。
final class FakeRestorePutClient: RestorePutClient, @unchecked Sendable {
    struct PutCall {
        let key: String
        let data: Data
        let viaMultipart: Bool
    }

    private let lock = NSLock()
    private var _putCalls: [PutCall] = []
    var putCalls: [PutCall] { lock.withLock { _putCalls } }
    let etag = "put-etag"
    let versionId: String? = "put-version"
    /// PUT（単発 / MPU complete）直後に呼ばれるフック（競合注入用）。
    var onPut: (@Sendable () async -> Void)?

    private var mpuParts: [Int: Data] = [:]

    func putObject(
        key: String, data: Data, contentType: String, metadata: [String: String],
        ifMatch: String?, ifNoneMatch: String?
    ) async throws -> TideS3Client.PutObjectResult {
        lock.withLock { _putCalls.append(PutCall(key: key, data: data, viaMultipart: false)) }
        await onPut?()
        return TideS3Client.PutObjectResult(etag: etag, versionId: versionId)
    }

    // MARK: - MultipartUploadClient

    func createMultipartUpload(
        key: String, contentType: String, metadata: [String: String]
    ) async throws -> String {
        lock.withLock { mpuParts = [:] }
        return "upload-1"
    }

    func uploadPart(key: String, uploadId: String, partNumber: Int, body: Data) async throws -> String {
        lock.withLock { mpuParts[partNumber] = body }
        return "part-etag-\(partNumber)"
    }

    func completeMultipartUpload(
        key: String, uploadId: String, parts: [(partNumber: Int, etag: String)]
    ) async throws -> TideS3Client.PutObjectResult {
        let joined = lock.withLock {
            mpuParts.sorted { $0.key < $1.key }.reduce(into: Data()) { $0.append($1.value) }
        }
        lock.withLock { _putCalls.append(PutCall(key: key, data: joined, viaMultipart: true)) }
        await onPut?()
        return TideS3Client.PutObjectResult(etag: etag, versionId: versionId)
    }

    func abortMultipartUpload(key: String, uploadId: String) async throws {}

    func headObject(key: String, versionId: String?) async throws -> TideS3Client.ObjectHead? {
        nil
    }
}
