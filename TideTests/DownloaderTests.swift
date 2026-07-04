import XCTest
import CryptoKit
import TideCore
@testable import Tide

/// `Downloader.download` の取得・再開・破棄ロジックを、フェイクの S3 ストリーミングシームと
/// 実 DB（一時ファイル）で検証する。DL 経路のユニットテスト負債（サブ A レビュー指摘）も返済する。
final class DownloaderTests: XCTestCase {
    // MARK: - ヘルパ

    private func makeEnv() throws -> (db: LocalDatabase, store: TransferStateStore, root: URL, tmp: URL) {
        let e = try makeTideTestEnv(prefix: "tide-dl-tests")
        return (e.db, e.store, e.root, e.tmp)
    }

    private func deterministicBytes(_ n: Int, salt: UInt8 = 0) -> Data {
        TestData.deterministicBytes(n, salt: salt)
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

    // seedShardState / shardEtag は TestSupport.swift の XCTestCase 拡張へ集約（TransferPruneTests と共用）。

    // MARK: - テスト

    /// 早期 return（ローカル内容がリモートと一致）は DB mtime に「ローカル stat 実値」を記録し、
    /// マニフェスト由来の秒切捨て値で上書きしない。これを欠くと、次回フルスキャンの
    /// `abs(DB.mtime - stat) < 0.001` 比較が必ず外れ、無変更ファイルが毎起動再アップロードされる
    /// （pull 汚染 → スキャン誤検出 → 再アップロード → シャード変化 → 再 pull の自己持続サイクル）。
    func testEarlyReturnRecordsLocalStatMtimeNotManifestTruncated() async throws {
        let env = try makeEnv()
        let data = deterministicBytes(2048)
        let rp = "docs/synced.bin"
        let local = env.root.appendingPathComponent(rp)
        try FileManager.default.createDirectory(
            at: local.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: local)
        // サブ秒精度の mtime を付与（ローカル発でアップロードされた直後のファイルを模擬）。
        // entry() のマニフェスト mtime "2026-06-04T00:00:00Z"（秒精度）とは大きく異なる値にして、
        // 「どちらが DB に記録されたか」を曖昧さなく判別できるようにする。
        let statMtime = Date(timeIntervalSince1970: 1_780_000_000.789)
        try FileManager.default.setAttributes(
            [.modificationDate: statMtime], ofItemAtPath: local.path
        )

        let fake = FakeRangedDownloadClient(fullData: data)
        let dl = makeDownloader(client: fake, db: env.db, store: env.store, root: env.root, tmp: env.tmp)
        let wrote = try await dl.download(relativePath: rp, entry: entry(for: data))

        XCTAssertFalse(wrote, "内容一致なので実書込しない（早期 return）")
        let rec = try await env.db.pool.read { db in try FileRecord.fetchOne(db, key: rp) }
        let recorded = try XCTUnwrap(rec).mtime
        XCTAssertEqual(
            recorded, statMtime.timeIntervalSince1970, accuracy: 0.0005,
            "DB.mtime はローカル stat 実値を記録する（マニフェスト切捨て値で上書きしない）"
        )
    }

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

    /// Issue #52（修正 C）: ローカル適用（親ディレクトリ作成 → move）の失敗はシャードキャッシュを
    /// re-arm し、tmp と再開行を破棄する。ファイル → 同名ディレクトリ置換の伝播窓では「祖先名が
    /// 既存ファイルで塞がれる」ため createDirectory が決定的に失敗するが、塞ぐ旧ファイルは後続 pull の
    /// 削除反映で除かれ、その後の再試行は成功する。re-arm を欠くと shard_state が「取得済み」のまま残り、
    /// FileRecord の無い端末（初回取得側）では DB 再合成にも乗らず、エラーの無いまま恒久的に取り残される。
    func testLocalApplyFailureRearmsShardCacheAndDiscardsTmp() async throws {
        let env = try makeEnv()
        // 親名 "x.txt" を既存ファイルで塞ぐ（種別変化の伝播窓を模擬）。
        try deterministicBytes(100, salt: 9).write(to: env.root.appendingPathComponent("x.txt"))

        let rp = "x.txt/inner.txt"
        let data = deterministicBytes(3000)
        // ManifestReader が fetch 時点で記録する shard_state を seed（re-arm の観測点）。
        try await seedShardState(db: env.db, path: rp, etag: "shard-etag-1")

        let fake = FakeRangedDownloadClient(fullData: data)
        let dl = makeDownloader(client: fake, db: env.db, store: env.store, root: env.root, tmp: env.tmp)

        do {
            _ = try await dl.download(relativePath: rp, entry: entry(for: data))
            XCTFail("親がファイルで塞がれているので失敗するはず")
        } catch {
            // expected（POSIX 17 / Cocoa 516 系のローカル I/O 失敗）
        }

        let etag = try await shardEtag(db: env.db, path: rp)
        XCTAssertEqual(etag, "", "ローカル適用失敗はシャードキャッシュを re-arm（sentinel 化）する")
        // tmp と再開行は破棄（完了サイズの tmp は resume 対象にならないため保持は無意味）。
        let tmpURL = Downloader.resumeTmpURL(in: env.tmp, relativePath: rp)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpURL.path))
        let row = try await env.store.loadDownload(path: rp)
        XCTAssertNil(row)
        // DB 反映は move 成功後のみ（FileRecord は作られない）。
        let rec = try await env.db.pool.read { db in try FileRecord.fetchOne(db, key: rp) }
        XCTAssertNil(rec)
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

    func testNetworkFailureRearmsShardCache() async throws {
        // PR #9 レビュー ②: ネットワーク失敗（resumable・部分 tmp 保持）は当該シャードの shard_state を
        // 空 etag に sentinel 化し、同一セッション中の次の poll/wake/network-up pull に再 fetch させる。
        let env = try makeEnv()
        let data = deterministicBytes(5000)
        let rp = "rearm.bin"
        try await seedShardState(db: env.db, path: rp, etag: "remote-abc")

        let fake = FakeRangedDownloadClient(fullData: data, failAfterBytes: 2048)
        let dl = makeDownloader(client: fake, db: env.db, store: env.store, root: env.root, tmp: env.tmp)

        do {
            _ = try await dl.download(relativePath: rp, entry: entry(for: data))
            XCTFail("ネットワーク失敗は throw すべき")
        } catch FakeDownloadError.injected {
            // 期待どおり。
        }

        // 行は残したまま etag だけ空 sentinel（removed-shard 検出の温存）。
        let etag = try await shardEtag(db: env.db, path: rp)
        XCTAssertEqual(etag, "")
    }

    func testInvalidateShardCacheWithoutRowIsNoop() async throws {
        // shard_state 行が無い（そのシャードは未 fetch）場合は no-op で成功する。
        let env = try makeEnv()
        let rp = "never-fetched.bin"
        try await env.db.invalidateShardCache(forPath: rp)
        let etag = try await shardEtag(db: env.db, path: rp)
        XCTAssertNil(etag, "行を新規作成してはならない")
    }

    func testShaMismatchDiscardsAndClears() async throws {
        let env = try makeEnv()
        let expected = deterministicBytes(5000, salt: 0)
        let served = deterministicBytes(5000, salt: 7)   // 同じ長さだが中身が違う
        let rp = "c.bin"
        try await seedShardState(db: env.db, path: rp, etag: "remote-abc")
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
        // 破棄系は再 arm しない（決定的に再失敗するのでリトライストームを避け、シャード etag 変化に委ねる）。
        let etag = try await shardEtag(db: env.db, path: rp)
        XCTAssertEqual(etag, "remote-abc")
    }

    func testOversizedTmpFromConcurrentAppendDiscardsAndClears() async throws {
        let env = try makeEnv()
        let data = deterministicBytes(4096)
        let rp = "over/size.bin"
        let tmpURL = Downloader.resumeTmpURL(in: env.tmp, relativePath: rp)
        // sink 経由の論理量は data 通り（hasher == entry.sha256 で SHA ゲートは通過する）が、
        // 別経路が tmp へ 64 バイト余分に追記して実ファイルが entry.size を超える状況を模擬。
        // commit 前の実サイズ検証（code -15）だけがこの破損を捕えるべき＝バグ①（並行 pull 破損）の防御線の回帰テスト。
        let fake = FakeRangedDownloadClient(fullData: data, corruptTmpURL: tmpURL, corruptExtraBytes: 64)
        let dl = makeDownloader(client: fake, db: env.db, store: env.store, root: env.root, tmp: env.tmp)

        do {
            _ = try await dl.download(relativePath: rp, entry: entry(for: data))
            XCTFail("過大サイズの tmp は破棄されるべき")
        } catch {
            guard case SyncError.ioError(let underlying) = error else {
                return XCTFail("想定外のエラー: \(error)")
            }
            XCTAssertEqual((underlying as NSError).code, -15, "実サイズ不一致ゲート（-15）で弾かれるべき")
        }

        // tmp 破棄・行クリア・完成ファイルなし。
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpURL.path))
        let row = try await env.store.loadDownload(path: rp)
        XCTAssertNil(row)
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.root.appendingPathComponent(rp).path))
    }

    func testNotFoundClearsAndThrows() async throws {
        let env = try makeEnv()
        let data = deterministicBytes(3000)
        let rp = "missing.bin"
        try await seedShardState(db: env.db, path: rp, etag: "remote-abc")
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
        // 404 も破棄系＝再 arm しない（削除の伝播はシャード etag 変化で届く）。
        let etag = try await shardEtag(db: env.db, path: rp)
        XCTAssertEqual(etag, "remote-abc")
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
    /// 並行追記の模擬（PR #9 レビュー ⑦）: 全チャンク送出後に、別経路（並行 reconcile / DL）が
    /// 共有 tmp へ余分なバイトを書き足したことにして、実ファイルを `entry.size` より過大にする。
    let corruptTmpURL: URL?
    let corruptExtraBytes: Int
    private(set) var lastRangeStart: Int64?
    private(set) var lastVersionId: String?
    private(set) var callCount = 0

    init(fullData: Data, etag: String = "etag-x", failAfterBytes: Int? = nil, notFound: Bool = false, chunkSize: Int = 1024, corruptTmpURL: URL? = nil, corruptExtraBytes: Int = 0) {
        self.fullData = fullData
        self.etag = etag
        self.failAfterBytes = failAfterBytes
        self.notFound = notFound
        self.chunkSize = chunkSize
        self.corruptTmpURL = corruptTmpURL
        self.corruptExtraBytes = corruptExtraBytes
    }

    func streamObject(
        key: String,
        versionId: String?,
        rangeStart: Int64?,
        limiter: RateLimiter?,
        sink: (Data) throws -> Void
    ) async throws -> TideS3Client.StreamObjectResult? {
        callCount += 1
        lastRangeStart = rangeStart
        lastVersionId = versionId
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
        // 並行追記の模擬: 全チャンク送出後（sink 経由の論理量は正しい＝SHA は一致する）に、
        // 別経路が共有 tmp へ余分なバイトを直接書き足したことにする。Downloader の commit 前
        // 実サイズ検証だけがこの過大化を捕えるべき（SHA ゲートは通過する）。
        if let url = corruptTmpURL, corruptExtraBytes > 0,
           let h = try? FileHandle(forWritingTo: url) {
            try? h.seekToEnd()
            try? h.write(contentsOf: Data(repeating: 0xEE, count: corruptExtraBytes))
            try? h.close()
        }
        return TideS3Client.StreamObjectResult(etag: etag, contentLength: Int64(slice.count))
    }
}
