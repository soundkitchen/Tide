import XCTest
import CryptoKit
@testable import Tide

/// `Downloader.download` の取得・再開・破棄ロジックを、フェイクの S3 ストリーミングシームと
/// 実 DB（一時ファイル）で検証する。DL 経路のユニットテスト負債（サブ A レビュー指摘）も返済する。
final class DownloaderTests: XCTestCase {
    // MARK: - ヘルパ

    private func makeEnv() throws -> (db: LocalDatabase, store: TransferStateStore, root: URL, tmp: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("tide-dl-tests-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("root", isDirectory: true)
        let tmp = base.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let db = try LocalDatabase(at: base.appendingPathComponent("db.sqlite"))
        return (db, TransferStateStore(db: db), root, tmp)
    }

    private func deterministicBytes(_ n: Int, salt: UInt8 = 0) -> Data {
        Data((0..<n).map { UInt8(($0 + Int(salt)) % 251) })
    }

    private func entry(for data: Data, etag: String = "etag-x") -> ManifestFileEntry {
        ManifestFileEntry(
            size: Int64(data.count),
            mtime: "2026-06-04T00:00:00Z",
            sha256: HashCalculator.hex(SHA256.hash(data: data)),
            s3VersionId: nil,
            etag: etag,
            deviceId: "devR",
            uploadedAt: "2026-06-04T00:00:00Z"
        )
    }

    private func makeDownloader(
        client: any RangedDownloadClient,
        db: LocalDatabase, store: TransferStateStore, root: URL, tmp: URL
    ) -> Downloader {
        Downloader(downloadClient: client, db: db, syncRoot: root, tmpDir: tmp, deviceId: "devL", transferStore: store)
    }

    // MARK: - テスト

    func testFreshDownloadWritesFileAndClears() async throws {
        let env = try makeEnv()
        let data = deterministicBytes(5000)
        let fake = FakeRangedDownloadClient(fullData: data)
        let dl = makeDownloader(client: fake, db: env.db, store: env.store, root: env.root, tmp: env.tmp)

        let wrote = try await dl.download(relativePath: "sub/file.bin", entry: entry(for: data))
        XCTAssertTrue(wrote)

        // 完成ファイルの内容が一致。
        let dest = env.root.appendingPathComponent("sub/file.bin")
        XCTAssertEqual(try Data(contentsOf: dest), data)
        // 新規なので Range なし。
        let rangeStart = fake.lastRangeStart
        XCTAssertNil(rangeStart)
        // 行はクリア、tmp は残らない。
        let row = try await env.store.loadDownload(path: "sub/file.bin")
        XCTAssertNil(row)
        let tmpURL = Downloader.resumeTmpURL(in: env.tmp, relativePath: "sub/file.bin")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpURL.path))
    }

    func testResumeFromPartial() async throws {
        let env = try makeEnv()
        let data = deterministicBytes(5000)
        let rp = "v/clip.bin"
        let tmpURL = Downloader.resumeTmpURL(in: env.tmp, relativePath: rp)

        // 先頭 2000 バイトを部分ダウンロード済みとして仕込む + 行を begin。
        try Data(data.prefix(2000)).write(to: tmpURL)
        try await env.store.beginDownload(path: rp, tmpPath: tmpURL.path, expectedEtag: "etag-x")

        let fake = FakeRangedDownloadClient(fullData: data, etag: "etag-x")
        let dl = makeDownloader(client: fake, db: env.db, store: env.store, root: env.root, tmp: env.tmp)

        let wrote = try await dl.download(relativePath: rp, entry: entry(for: data, etag: "etag-x"))
        XCTAssertTrue(wrote)

        // 2000 バイト目から Range 再開。
        let rangeStart = fake.lastRangeStart
        XCTAssertEqual(rangeStart, 2000)
        // 全体 SHA を復元できているので完成内容が一致。
        let dest = env.root.appendingPathComponent(rp)
        XCTAssertEqual(try Data(contentsOf: dest), data)
        // 行はクリア。
        let row = try await env.store.loadDownload(path: rp)
        XCTAssertNil(row)
    }

    func testEtagMismatchRestartsFresh() async throws {
        let env = try makeEnv()
        let data = deterministicBytes(5000)
        let rp = "a.bin"
        let tmpURL = Downloader.resumeTmpURL(in: env.tmp, relativePath: rp)

        // 部分ダウンロードはあるが、保存した expected etag が現エントリと食い違う。
        try Data(data.prefix(2000)).write(to: tmpURL)
        try await env.store.beginDownload(path: rp, tmpPath: tmpURL.path, expectedEtag: "OLD-etag")

        let fake = FakeRangedDownloadClient(fullData: data, etag: "etag-x")
        let dl = makeDownloader(client: fake, db: env.db, store: env.store, root: env.root, tmp: env.tmp)

        let wrote = try await dl.download(relativePath: rp, entry: entry(for: data, etag: "etag-x"))
        XCTAssertTrue(wrote)

        // 部分を破棄してフル取得（Range なし）。
        let rangeStart = fake.lastRangeStart
        XCTAssertNil(rangeStart)
        let dest = env.root.appendingPathComponent(rp)
        XCTAssertEqual(try Data(contentsOf: dest), data)
    }

    func testNetworkFailureKeepsPartial() async throws {
        let env = try makeEnv()
        let data = deterministicBytes(5000)
        let rp = "big.bin"
        // 2048 バイト送ったところで失敗注入。
        let fake = FakeRangedDownloadClient(fullData: data, failAfterBytes: 2048)
        let dl = makeDownloader(client: fake, db: env.db, store: env.store, root: env.root, tmp: env.tmp)

        do {
            _ = try await dl.download(relativePath: rp, entry: entry(for: data))
            XCTFail("ネットワーク失敗は throw すべき")
        } catch FakeDownloadError.injected {
            // 期待どおり。
        }

        // 部分 tmp と行を保持（次回 Range 再開のため）。
        let tmpURL = Downloader.resumeTmpURL(in: env.tmp, relativePath: rp)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpURL.path))
        let size = Downloader.fileSize(at: tmpURL)
        XCTAssertNotNil(size)
        XCTAssertGreaterThan(size ?? 0, 0)
        XCTAssertLessThan(size ?? .max, 5000)
        let row = try await env.store.loadDownload(path: rp)
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.tmpPath, tmpURL.path)
        // 完成ファイルは作られていない。
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.root.appendingPathComponent(rp).path))
    }

    func testShaMismatchDiscardsAndClears() async throws {
        let env = try makeEnv()
        let expected = deterministicBytes(5000, salt: 0)
        let served = deterministicBytes(5000, salt: 7)   // 同じ長さだが中身が違う
        let rp = "c.bin"
        let fake = FakeRangedDownloadClient(fullData: served)
        let dl = makeDownloader(client: fake, db: env.db, store: env.store, root: env.root, tmp: env.tmp)

        do {
            _ = try await dl.download(relativePath: rp, entry: entry(for: expected))
            XCTFail("SHA 不一致は throw すべき")
        } catch {
            guard case SyncError.ioError = error else { return XCTFail("想定外のエラー: \(error)") }
        }

        // tmp 破棄・行クリア・完成ファイルなし。
        let tmpURL = Downloader.resumeTmpURL(in: env.tmp, relativePath: rp)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpURL.path))
        let row = try await env.store.loadDownload(path: rp)
        XCTAssertNil(row)
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.root.appendingPathComponent(rp).path))
    }

    func testNotFoundClearsAndThrows() async throws {
        let env = try makeEnv()
        let data = deterministicBytes(3000)
        let rp = "missing.bin"
        let fake = FakeRangedDownloadClient(fullData: data, notFound: true)
        let dl = makeDownloader(client: fake, db: env.db, store: env.store, root: env.root, tmp: env.tmp)

        do {
            _ = try await dl.download(relativePath: rp, entry: entry(for: data))
            XCTFail("404 は throw すべき")
        } catch {
            guard case SyncError.ioError = error else { return XCTFail("想定外のエラー: \(error)") }
        }

        let tmpURL = Downloader.resumeTmpURL(in: env.tmp, relativePath: rp)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpURL.path))
        let row = try await env.store.loadDownload(path: rp)
        XCTAssertNil(row)
    }
}

// MARK: - フェイク

enum FakeDownloadError: Error { case injected }

/// `RangedDownloadClient` のテスト用フェイク。`fullData` の `rangeStart` 以降を小さなチャンクで `sink` へ流す。
/// `failAfterBytes` で送出途中の失敗を、`notFound` で 404 を注入できる。class なので非 Sendable な
/// `sink` クロージャをそのまま受けられる（actor だと境界越えで Sendable を要求される）。
final class FakeRangedDownloadClient: RangedDownloadClient, @unchecked Sendable {
    let fullData: Data
    let etag: String
    let failAfterBytes: Int?
    let notFound: Bool
    let chunkSize: Int
    private(set) var lastRangeStart: Int64?
    private(set) var callCount = 0

    init(fullData: Data, etag: String = "etag-x", failAfterBytes: Int? = nil, notFound: Bool = false, chunkSize: Int = 1024) {
        self.fullData = fullData
        self.etag = etag
        self.failAfterBytes = failAfterBytes
        self.notFound = notFound
        self.chunkSize = chunkSize
    }

    func streamObject(
        key: String,
        rangeStart: Int64?,
        sink: (Data) throws -> Void
    ) async throws -> TideS3Client.StreamObjectResult? {
        callCount += 1
        lastRangeStart = rangeStart
        if notFound { return nil }
        let start = Int(rangeStart ?? 0)
        guard start <= fullData.count else {
            return TideS3Client.StreamObjectResult(etag: etag, contentLength: 0)
        }
        let slice = fullData.subdata(in: start..<fullData.count)
        var delivered = 0
        var idx = 0
        while idx < slice.count {
            let end = min(idx + chunkSize, slice.count)
            try sink(slice.subdata(in: idx..<end))
            delivered += (end - idx)
            if let fa = failAfterBytes, delivered >= fa { throw FakeDownloadError.injected }
            idx = end
        }
        return TideS3Client.StreamObjectResult(etag: etag, contentLength: Int64(slice.count))
    }
}
