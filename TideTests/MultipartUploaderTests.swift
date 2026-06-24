import XCTest
import CryptoKit
@testable import Tide

final class MultipartUploaderTests: XCTestCase {
    /// テスト用の短い遅延方針（本番の指数バックオフをほぼ即時に）。
    private static let fastPolicy = MultipartUploader.RetryPolicy(
        maxAttempts: 3, baseDelaySeconds: 0.001, maxDelaySeconds: 0.01
    )

    // MARK: - ヘルパ

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tide-mp-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func writeFile(_ data: Data, in dir: URL, name: String = "blob.bin") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// 決定的で非自明な内容（全部同じバイトだと連結検証が緩くなるため）。
    private func deterministicBytes(_ count: Int) -> Data { TestData.deterministicBytes(count) }

    // MARK: - テスト

    func testHashAndPartsRoundTrip() async throws {
        let dir = tempDir()
        let data = deterministicBytes(4500)            // partSize 1024 → 5 パート（1024×4 + 404）
        let url = try writeFile(data, in: dir)
        let fake = FakeMultipartClient()
        let reader = try NoFollowFileReader(path: url.path)
        defer { reader.close() }

        let uploader = MultipartUploader(s3: fake, retryPolicy: Self.fastPolicy)
        let result = try await uploader.upload(
            key: "files/blob.bin", reader: reader, partSize: 1024, metadata: ["device": "devA"]
        )

        // CreateMultipartUpload は 1 回・正しい key と metadata。
        let createCount = await fake.createCount
        XCTAssertEqual(createCount, 1)
        let createKey = await fake.lastCreateKey
        XCTAssertEqual(createKey, "files/blob.bin")
        let meta = await fake.lastCreateMetadata
        XCTAssertEqual(meta["device"], "devA")

        // 5 パート・番号 1..5・各 1 回試行。
        let bodies = await fake.bodies
        XCTAssertEqual(bodies.keys.sorted(), [1, 2, 3, 4, 5])
        let attempts = await fake.attemptsByPart
        XCTAssertEqual(attempts, [1: 1, 2: 1, 3: 1, 4: 1, 5: 1])

        // 連結 == 元データ（並列でも読み順＝パート番号順で復元できる）。
        let reassembled = (1...5).reduce(Data()) { $0 + (bodies[$1] ?? Data()) }
        XCTAssertEqual(reassembled, data)

        // SHA-256 は独立計算と一致。
        let expectedSha = HashCalculator.hex(SHA256.hash(data: data))
        XCTAssertEqual(result.sha256, expectedSha)

        // CompleteMultipartUpload は全パートを受領（番号昇順整列で 1..5、etag は etag-N）。
        let completed = await fake.completedParts
        let sorted = completed?.sorted { $0.partNumber < $1.partNumber }
        XCTAssertEqual(sorted?.map { $0.partNumber }, [1, 2, 3, 4, 5])
        XCTAssertEqual(sorted?.map { $0.etag }, (1...5).map { "etag-\($0)" })

        // 返り put はフェイクの complete 結果。
        XCTAssertEqual(result.put.etag, "complete-etag")
        XCTAssertEqual(result.put.versionId, "v1")

        // 正常系で abort は呼ばれない。
        let abortCount = await fake.abortCount
        XCTAssertEqual(abortCount, 0)
    }

    func testSinglePartProducesOnePart() async throws {
        let dir = tempDir()
        let data = deterministicBytes(500)             // < partSize → 1 パート
        let url = try writeFile(data, in: dir)
        let fake = FakeMultipartClient()
        let reader = try NoFollowFileReader(path: url.path)
        defer { reader.close() }

        let uploader = MultipartUploader(s3: fake, retryPolicy: Self.fastPolicy)
        let result = try await uploader.upload(key: "files/blob.bin", reader: reader, partSize: 1024)

        let bodies = await fake.bodies
        XCTAssertEqual(bodies.keys.sorted(), [1])
        XCTAssertEqual(bodies[1], data)
        XCTAssertEqual(result.sha256, HashCalculator.hex(SHA256.hash(data: data)))
    }

    func testEmptyFileThrowsAndAborts() async throws {
        let dir = tempDir()
        let url = try writeFile(Data(), in: dir)       // 0 バイト → parts 空（L10 ガード）
        let fake = FakeMultipartClient()
        let reader = try NoFollowFileReader(path: url.path)
        defer { reader.close() }

        let uploader = MultipartUploader(s3: fake, retryPolicy: Self.fastPolicy)
        do {
            _ = try await uploader.upload(key: "files/blob.bin", reader: reader, partSize: 1024)
            XCTFail("空ファイルは throw すべき")
        } catch {
            // SyncError.ioError が投げられる。
            guard case SyncError.ioError = error else {
                return XCTFail("想定外のエラー: \(error)")
            }
        }

        // best-effort abort が呼ばれ、complete は呼ばれない。
        let abortCount = await fake.abortCount
        XCTAssertEqual(abortCount, 1)
        let completed = await fake.completedParts
        XCTAssertNil(completed)
    }

    func testTransientPartFailureRetried() async throws {
        let dir = tempDir()
        let data = deterministicBytes(4500)            // 5 パート
        let url = try writeFile(data, in: dir)
        // パート 2 は 1 回だけ失敗 → リトライで成功。
        let fake = FakeMultipartClient(failuresByPart: [2: 1])
        let reader = try NoFollowFileReader(path: url.path)
        defer { reader.close() }

        let uploader = MultipartUploader(s3: fake, retryPolicy: Self.fastPolicy)
        let result = try await uploader.upload(key: "files/blob.bin", reader: reader, partSize: 1024)

        let attempts = await fake.attemptsByPart
        XCTAssertEqual(attempts[2], 2, "パート 2 は失敗 1 回 + 成功 1 回 = 2 試行")
        let bodies = await fake.bodies
        XCTAssertEqual(bodies.keys.sorted(), [1, 2, 3, 4, 5])
        XCTAssertEqual(result.sha256, HashCalculator.hex(SHA256.hash(data: data)))
        let abortCount = await fake.abortCount
        XCTAssertEqual(abortCount, 0)
    }

    func testPermanentPartFailureAbortsAndThrows() async throws {
        let dir = tempDir()
        let data = deterministicBytes(4500)
        let url = try writeFile(data, in: dir)
        // パート 2 は常に失敗 → maxAttempts 到達で throw。
        let fake = FakeMultipartClient(alwaysFailParts: [2])
        let reader = try NoFollowFileReader(path: url.path)
        defer { reader.close() }

        let uploader = MultipartUploader(s3: fake, retryPolicy: Self.fastPolicy)
        do {
            _ = try await uploader.upload(key: "files/blob.bin", reader: reader, partSize: 1024)
            XCTFail("恒久失敗は throw すべき")
        } catch FakeS3Error.injected {
            // 期待どおり伝播。
        }

        let attempts = await fake.attemptsByPart
        XCTAssertEqual(attempts[2], Self.fastPolicy.maxAttempts, "パート 2 は maxAttempts 回試行")
        let abortCount = await fake.abortCount
        XCTAssertEqual(abortCount, 1, "恒久失敗時は best-effort abort")
        let completed = await fake.completedParts
        XCTAssertNil(completed)
    }

    // MARK: - L6 (A-detect): 読込中にファイルが変化したら complete せず abort

    /// 安定なら従来どおり complete する（expectedStat を渡しても happy path を壊さない）。
    func testStableExpectedStatStillCompletes() async throws {
        let dir = tempDir()
        let data = deterministicBytes(4500)
        let url = try writeFile(data, in: dir)
        let fake = FakeMultipartClient()
        let reader = try NoFollowFileReader(path: url.path)
        defer { reader.close() }
        let real = try reader.info()                    // 現ファイルの stat（= 読み終え後も不変）

        let uploader = MultipartUploader(s3: fake, retryPolicy: Self.fastPolicy)
        let result = try await uploader.upload(
            key: "files/blob.bin", reader: reader, partSize: 1024, expectedStat: real
        )

        XCTAssertEqual(result.sha256, HashCalculator.hex(SHA256.hash(data: data)))
        let completed = await fake.completedParts
        let abortCount = await fake.abortCount
        XCTAssertNotNil(completed, "安定なら complete する")
        XCTAssertEqual(abortCount, 0)
    }

    /// 不安定なら complete せず abort + throw（現行 S3 オブジェクトを torn で上書きしない）。
    /// 読込中の変化は、現ファイルと食い違う expectedStat を渡して模す
    /// （読み終え後の reader.info() = 現ファイルと一致しない → 不安定判定）。
    func testFileChangedDuringUploadAbortsAndThrows() async throws {
        let dir = tempDir()
        let data = deterministicBytes(4500)
        let url = try writeFile(data, in: dir)
        let fake = FakeMultipartClient()
        let reader = try NoFollowFileReader(path: url.path)
        defer { reader.close() }
        let real = try reader.info()
        let expected = NoFollowFileReader.FileInfo(size: real.size + 1, mtime: real.mtime)

        let uploader = MultipartUploader(s3: fake, retryPolicy: Self.fastPolicy)
        do {
            _ = try await uploader.upload(
                key: "files/blob.bin", reader: reader, partSize: 1024, expectedStat: expected
            )
            XCTFail("不安定なら throw すべき")
        } catch {
            guard case SyncError.fileChangedDuringUpload = error else {
                return XCTFail("想定外のエラー: \(error)")
            }
        }

        let completed = await fake.completedParts
        let abortCount = await fake.abortCount
        XCTAssertNil(completed, "complete は呼ばれない")
        XCTAssertEqual(abortCount, 1, "不安定なら 1 回だけ abort（catch の二重 abort を起こさない）")
    }

    /// resume 付きでも不安定なら abort + checkpoint クリア（stale MPU を残さずフル再開に委ねる）。
    func testFileChangedWithResumeAbortsAndClearsCheckpoint() async throws {
        let dir = tempDir()
        let data = deterministicBytes(4500)
        let url = try writeFile(data, in: dir)
        let fake = FakeMultipartClient()
        let ckpt = FakeUploadCheckpointStore()
        let reader = try NoFollowFileReader(path: url.path)
        defer { reader.close() }
        let real = try reader.info()
        let resume = MultipartUploader.ResumeContext(
            path: "blob.bin", fileMtime: real.mtime.timeIntervalSince1970, fileSize: real.size, store: ckpt
        )
        let expected = NoFollowFileReader.FileInfo(size: real.size, mtime: real.mtime.addingTimeInterval(5))

        let uploader = MultipartUploader(s3: fake, retryPolicy: Self.fastPolicy)
        do {
            _ = try await uploader.upload(
                key: "files/blob.bin", reader: reader, partSize: 1024,
                resume: resume, expectedStat: expected
            )
            XCTFail("不安定なら throw すべき")
        } catch {
            guard case SyncError.fileChangedDuringUpload = error else {
                return XCTFail("想定外のエラー: \(error)")
            }
        }

        let abortCount = await fake.abortCount
        let clearCount = await ckpt.clearCount
        XCTAssertEqual(abortCount, 1, "resume でも不安定なら abort")
        XCTAssertEqual(clearCount, 1, "stale checkpoint をクリアして次回フル再開に委ねる")
        let leftover = try await ckpt.loadUpload(path: "blob.bin")
        XCTAssertNil(leftover)
    }

    /// 成長検知の early-bail: 読了量が開始時 size を超えた時点で、全パートを上げ切る前に throw する
    /// （満額 PUT → abort の浪費を避ける）。開始時 size を実ファイルより小さく渡して成長を模す。
    func testEarlyBailOnGrowthBeforeUploadingAllParts() async throws {
        let dir = tempDir()
        let data = deterministicBytes(4500)             // partSize 1024 → 本来 5 パート
        let url = try writeFile(data, in: dir)
        let fake = FakeMultipartClient()
        let reader = try NoFollowFileReader(path: url.path)
        defer { reader.close() }
        let real = try reader.info()
        // size を 2000 に偽装（mtime は一致させ、成長条件だけを発火させる）。
        // 読了量がパート2で 2048 > 2000 → パート2を PUT する前に throw。
        let expected = NoFollowFileReader.FileInfo(size: 2000, mtime: real.mtime)

        let uploader = MultipartUploader(s3: fake, retryPolicy: Self.fastPolicy)
        do {
            _ = try await uploader.upload(
                key: "files/blob.bin", reader: reader, partSize: 1024, expectedStat: expected
            )
            XCTFail("成長検知で throw すべき")
        } catch {
            guard case SyncError.fileChangedDuringUpload = error else {
                return XCTFail("想定外のエラー: \(error)")
            }
        }

        let bodies = await fake.bodies
        let completed = await fake.completedParts
        let abortCount = await fake.abortCount
        XCTAssertTrue(bodies.keys.allSatisfy { $0 <= 1 }, "全 5 パートは上げない（早期 bail）。アップロード済みはパート1まで")
        XCTAssertNil(completed, "complete は呼ばれない")
        XCTAssertEqual(abortCount, 1)
    }

    /// in-place 同サイズ書換の early-bail: mtime 前進を逐次検知し、最初のパートを PUT する前に throw する。
    /// 開始時 mtime を実ファイルより過去に渡して「読込中に mtime が前進した」状況を模す。
    func testEarlyBailOnMtimeAdvanceBeforeAnyPart() async throws {
        let dir = tempDir()
        let data = deterministicBytes(4500)
        let url = try writeFile(data, in: dir)
        let fake = FakeMultipartClient()
        let reader = try NoFollowFileReader(path: url.path)
        defer { reader.close() }
        let real = try reader.info()
        // size は一致（成長条件は発火しない）、mtime だけ過去 → 1 パート目の検査で mtime 不一致 → 即 throw。
        let expected = NoFollowFileReader.FileInfo(size: real.size, mtime: real.mtime.addingTimeInterval(-5))

        let uploader = MultipartUploader(s3: fake, retryPolicy: Self.fastPolicy)
        do {
            _ = try await uploader.upload(
                key: "files/blob.bin", reader: reader, partSize: 1024, expectedStat: expected
            )
            XCTFail("mtime 前進で throw すべき")
        } catch {
            guard case SyncError.fileChangedDuringUpload = error else {
                return XCTFail("想定外のエラー: \(error)")
            }
        }

        let bodies = await fake.bodies
        let completed = await fake.completedParts
        let abortCount = await fake.abortCount
        XCTAssertTrue(bodies.isEmpty, "1 パートも上げずに bail する")
        XCTAssertNil(completed)
        XCTAssertEqual(abortCount, 1)
    }

    // MARK: - 中断・再開（D2）

    /// resume コンテキスト付きの新規アップロード: begin → 各パートを checkpoint 記録 → 成功で clear。
    func testResumeFreshUploadPersistsThenClears() async throws {
        let dir = tempDir()
        let data = deterministicBytes(4500)            // 5 パート @1024
        let url = try writeFile(data, in: dir)
        let fake = FakeMultipartClient()
        let ckpt = FakeUploadCheckpointStore()
        let reader = try NoFollowFileReader(path: url.path)
        defer { reader.close() }
        let info = try reader.info()
        let resume = MultipartUploader.ResumeContext(
            path: "blob.bin", fileMtime: info.mtime.timeIntervalSince1970, fileSize: info.size, store: ckpt
        )

        let uploader = MultipartUploader(s3: fake, retryPolicy: Self.fastPolicy)
        let result = try await uploader.upload(
            key: "files/blob.bin", reader: reader, partSize: 1024, resume: resume
        )

        // 新規なので create / begin が 1 回ずつ。
        let createCount = await fake.createCount
        let beginCount = await ckpt.beginCount
        XCTAssertEqual(createCount, 1)
        XCTAssertEqual(beginCount, 1)
        // 5 パートすべて送信。
        let bodyKeys = (await fake.bodies).keys.sorted()
        XCTAssertEqual(bodyKeys, [1, 2, 3, 4, 5])
        // 5 パートすべて checkpoint 記録。
        let recorded = await ckpt.recordedParts["blob.bin"]?.map { $0.n }.sorted()
        XCTAssertEqual(recorded, [1, 2, 3, 4, 5])
        // 成功で行をクリア（再開状態は残さない）。
        let clearCount = await ckpt.clearCount
        XCTAssertEqual(clearCount, 1)
        let leftover = try await ckpt.loadUpload(path: "blob.bin")
        XCTAssertNil(leftover)
        // SHA は全体一致・abort なし。
        XCTAssertEqual(result.sha256, HashCalculator.hex(SHA256.hash(data: data)))
        let abortCount = await fake.abortCount
        XCTAssertEqual(abortCount, 0)
    }

    /// mtime/size 一致の既存 checkpoint があれば、完了済みパートは送らず未送だけ送る。
    /// 既送パートも読み順に hash 更新されるので全体 SHA は正しく復元される。
    func testResumeSkipsCompletedParts() async throws {
        let dir = tempDir()
        let data = deterministicBytes(4500)            // 5 パート @1024
        let url = try writeFile(data, in: dir)
        let reader = try NoFollowFileReader(path: url.path)
        defer { reader.close() }
        let info = try reader.info()

        // パート 1..3 を完了済みとして仕込む（mtime/size は現ファイルと一致）。
        let seed = UploadResumeState(
            uploadId: "resume-up", partSize: 1024,
            completedParts: [
                CompletedPart(n: 1, etag: "seed-1"),
                CompletedPart(n: 2, etag: "seed-2"),
                CompletedPart(n: 3, etag: "seed-3"),
            ],
            fileMtime: info.mtime.timeIntervalSince1970, fileSize: info.size
        )
        let ckpt = FakeUploadCheckpointStore(seed: ["blob.bin": seed])
        let fake = FakeMultipartClient()
        let resume = MultipartUploader.ResumeContext(
            path: "blob.bin", fileMtime: info.mtime.timeIntervalSince1970, fileSize: info.size, store: ckpt
        )

        let uploader = MultipartUploader(s3: fake, retryPolicy: Self.fastPolicy)
        let result = try await uploader.upload(
            key: "files/blob.bin", reader: reader, partSize: 1024, resume: resume
        )

        // 既存 MPU を再開＝新規 create も begin もしない。
        let createCount = await fake.createCount
        let beginCount = await ckpt.beginCount
        XCTAssertEqual(createCount, 0)
        XCTAssertEqual(beginCount, 0)
        // 未送パート 4,5 のみ送信。
        let bodyKeys = (await fake.bodies).keys.sorted()
        XCTAssertEqual(bodyKeys, [4, 5])
        // Complete は 5 パート（1..3 は seed の etag、4,5 は新規 etag）。
        let completed = (await fake.completedParts)?.sorted { $0.partNumber < $1.partNumber }
        XCTAssertEqual(completed?.map { $0.partNumber }, [1, 2, 3, 4, 5])
        XCTAssertEqual(completed?.map { $0.etag }, ["seed-1", "seed-2", "seed-3", "etag-4", "etag-5"])
        // 全体 SHA は元データと一致（既送分も読み順に hash 更新したため）。
        XCTAssertEqual(result.sha256, HashCalculator.hex(SHA256.hash(data: data)))
        // 成功でクリア・abort なし。
        let clearCount = await ckpt.clearCount
        let abortCount = await fake.abortCount
        XCTAssertEqual(clearCount, 1)
        XCTAssertEqual(abortCount, 0)
    }

    /// 既存 checkpoint があっても mtime/size が変わっていれば、古い MPU を abort してフル再開する。
    func testResumeFileChangedAbortsStaleAndRestarts() async throws {
        let dir = tempDir()
        let data = deterministicBytes(4500)
        let url = try writeFile(data, in: dir)
        let reader = try NoFollowFileReader(path: url.path)
        defer { reader.close() }
        let info = try reader.info()

        // mtime も size も現ファイルと食い違う stale な行。
        let stale = UploadResumeState(
            uploadId: "stale-up", partSize: 1024,
            completedParts: [CompletedPart(n: 1, etag: "old-1")],
            fileMtime: info.mtime.timeIntervalSince1970 - 1000, fileSize: info.size + 999
        )
        let ckpt = FakeUploadCheckpointStore(seed: ["blob.bin": stale])
        let fake = FakeMultipartClient()
        let resume = MultipartUploader.ResumeContext(
            path: "blob.bin", fileMtime: info.mtime.timeIntervalSince1970, fileSize: info.size, store: ckpt
        )

        let uploader = MultipartUploader(s3: fake, retryPolicy: Self.fastPolicy)
        let result = try await uploader.upload(
            key: "files/blob.bin", reader: reader, partSize: 1024, resume: resume
        )

        // 古い MPU を abort、フル再開（create + begin）。
        let aborted = await fake.abortedUploadIds
        let createCount = await fake.createCount
        let beginCount = await ckpt.beginCount
        XCTAssertEqual(aborted, ["stale-up"])
        XCTAssertEqual(createCount, 1)
        XCTAssertEqual(beginCount, 1)
        // 全 5 パートを最初から送る。
        let bodyKeys = (await fake.bodies).keys.sorted()
        XCTAssertEqual(bodyKeys, [1, 2, 3, 4, 5])
        XCTAssertEqual(result.sha256, HashCalculator.hex(SHA256.hash(data: data)))
        let clearCount = await ckpt.clearCount
        XCTAssertEqual(clearCount, 1)
    }

    /// resume 付きで恒久失敗したら、abort も clear もせず checkpoint を保持する
    /// （次回のファイル単位リトライ / 次回起動で再開できるように）。
    func testResumePreservedOnPermanentFailure() async throws {
        let dir = tempDir()
        let data = deterministicBytes(4500)
        let url = try writeFile(data, in: dir)
        let reader = try NoFollowFileReader(path: url.path)
        defer { reader.close() }
        let info = try reader.info()

        let fake = FakeMultipartClient(alwaysFailParts: [3])   // パート 3 が恒久失敗
        let ckpt = FakeUploadCheckpointStore()
        let resume = MultipartUploader.ResumeContext(
            path: "blob.bin", fileMtime: info.mtime.timeIntervalSince1970, fileSize: info.size, store: ckpt
        )

        let uploader = MultipartUploader(s3: fake, retryPolicy: Self.fastPolicy)
        do {
            _ = try await uploader.upload(key: "files/blob.bin", reader: reader, partSize: 1024, resume: resume)
            XCTFail("恒久失敗は throw すべき")
        } catch FakeS3Error.injected {
            // 期待どおり伝播。
        }

        // resume あり: abort も clear もしない（MPU と checkpoint を保持）。
        let abortCount = await fake.abortCount
        let clearCount = await ckpt.clearCount
        XCTAssertEqual(abortCount, 0)
        XCTAssertEqual(clearCount, 0)
        // 行は残存し、新規 create の UploadId で begin 済み。
        let surviving = try await ckpt.loadUpload(path: "blob.bin")
        XCTAssertNotNil(surviving)
        XCTAssertEqual(surviving?.uploadId, "upload-id-xyz")
    }

    // MARK: - stale UploadId 回復（Issue #33）

    /// 経路1: complete 成功 → clearUpload 前にクラッシュ → 次回再開で死んだ UploadId を complete →
    /// NoSuchUpload。本体は既に S3 に上がっているので headObject で identity を回収して成功扱いにする。
    func testNoSuchUploadOnCompleteRecoversViaHeadObject() async throws {
        let dir = tempDir()
        let data = deterministicBytes(4500)            // 5 パート @1024
        let url = try writeFile(data, in: dir)
        let reader = try NoFollowFileReader(path: url.path)
        defer { reader.close() }
        let info = try reader.info()

        // 全 5 パート完了済みの checkpoint（= complete 済みでクラッシュした状態の再現）。mtime/size 一致。
        let seed = UploadResumeState(
            uploadId: "completed-up", partSize: 1024,
            completedParts: (1...5).map { CompletedPart(n: $0, etag: "seed-\($0)") },
            fileMtime: info.mtime.timeIntervalSince1970, fileSize: info.size
        )
        let ckpt = FakeUploadCheckpointStore(seed: ["blob.bin": seed])
        // complete は NoSuchUpload、headObject は本体（サイズ一致）を返す。
        let recoveredHead = TideS3Client.ObjectHead(
            etag: "recovered-etag", versionId: "recovered-v", size: info.size, metadata: [:]
        )
        let fake = FakeMultipartClient(
            completeError: DescribedS3Error.noSuchUpload, headResult: recoveredHead
        )
        let resume = MultipartUploader.ResumeContext(
            path: "blob.bin", fileMtime: info.mtime.timeIntervalSince1970, fileSize: info.size, store: ckpt
        )

        let uploader = MultipartUploader(s3: fake, retryPolicy: Self.fastPolicy)
        let result = try await uploader.upload(
            key: "files/blob.bin", reader: reader, partSize: 1024, resume: resume
        )

        // headObject で回収した identity が結果に乗る。
        XCTAssertEqual(result.put.etag, "recovered-etag")
        XCTAssertEqual(result.put.versionId, "recovered-v")
        // 全体 SHA は元データ一致（既送分も読み順に hash 更新したため）。
        XCTAssertEqual(result.sha256, HashCalculator.hex(SHA256.hash(data: data)))
        // 全パート完了済み＝新規 uploadPart なし、create/begin なし。
        let bodyKeys = (await fake.bodies).keys.sorted()
        let createCount = await fake.createCount
        XCTAssertEqual(bodyKeys, [])
        XCTAssertEqual(createCount, 0)
        // headObject は対象キーへ 1 回。
        let headCount = await fake.headCount
        let headKey = await fake.lastHeadKey
        XCTAssertEqual(headCount, 1)
        XCTAssertEqual(headKey, "files/blob.bin")
        // 成功扱いなので checkpoint をクリア・abort なし。
        let clearCount = await ckpt.clearCount
        let abortCount = await fake.abortCount
        XCTAssertEqual(clearCount, 1)
        XCTAssertEqual(abortCount, 0)
        let leftover = try await ckpt.loadUpload(path: "blob.bin")
        XCTAssertNil(leftover)
    }

    /// complete が NoSuchUpload だが本体も存在しない（MPU が本当に失われた）→ 成功扱いにできない。
    /// stale checkpoint を破棄して rethrow し、次回フル再開に委ねる。
    func testNoSuchUploadOnCompleteWithMissingObjectClearsAndRethrows() async throws {
        let dir = tempDir()
        let data = deterministicBytes(4500)
        let url = try writeFile(data, in: dir)
        let reader = try NoFollowFileReader(path: url.path)
        defer { reader.close() }
        let info = try reader.info()

        let seed = UploadResumeState(
            uploadId: "completed-up", partSize: 1024,
            completedParts: (1...5).map { CompletedPart(n: $0, etag: "seed-\($0)") },
            fileMtime: info.mtime.timeIntervalSince1970, fileSize: info.size
        )
        let ckpt = FakeUploadCheckpointStore(seed: ["blob.bin": seed])
        // complete は NoSuchUpload、headObject は nil（本体が無い）。
        let fake = FakeMultipartClient(
            completeError: DescribedS3Error.noSuchUpload, headResult: nil
        )
        let resume = MultipartUploader.ResumeContext(
            path: "blob.bin", fileMtime: info.mtime.timeIntervalSince1970, fileSize: info.size, store: ckpt
        )

        let uploader = MultipartUploader(s3: fake, retryPolicy: Self.fastPolicy)
        do {
            _ = try await uploader.upload(key: "files/blob.bin", reader: reader, partSize: 1024, resume: resume)
            XCTFail("回収不能な NoSuchUpload は throw すべき")
        } catch let e as DescribedS3Error {
            XCTAssertTrue(e.description.contains("NoSuchUpload"))
        }

        // headObject を引いたが nil → checkpoint を破棄（次回フル再開）。abort はしない。
        let headCount = await fake.headCount
        let clearCount = await ckpt.clearCount
        let abortCount = await fake.abortCount
        XCTAssertEqual(headCount, 1)
        XCTAssertEqual(clearCount, 1)
        XCTAssertEqual(abortCount, 0)
        let leftover = try await ckpt.loadUpload(path: "blob.bin")
        XCTAssertNil(leftover)
    }

    /// 経路2: 7 日ライフサイクルで失効した MPU を再開 → uploadPart が NoSuchUpload。保持して再開し続ける
    /// と「変更されるまで永久に上がらない」ので、stale checkpoint を破棄して次回フル再開に委ねる。
    func testNoSuchUploadOnUploadPartClearsCheckpointForFreshRestart() async throws {
        let dir = tempDir()
        let data = deterministicBytes(4500)            // 5 パート @1024
        let url = try writeFile(data, in: dir)
        let reader = try NoFollowFileReader(path: url.path)
        defer { reader.close() }
        let info = try reader.info()

        // パート 1..3 完了済み（mtime/size 一致）→ 4,5 を送ろうとする。
        let seed = UploadResumeState(
            uploadId: "expired-up", partSize: 1024,
            completedParts: (1...3).map { CompletedPart(n: $0, etag: "seed-\($0)") },
            fileMtime: info.mtime.timeIntervalSince1970, fileSize: info.size
        )
        let ckpt = FakeUploadCheckpointStore(seed: ["blob.bin": seed])
        // 未送パートの uploadPart が NoSuchUpload で失効を表現。
        let fake = FakeMultipartClient(
            alwaysFailParts: [4, 5], partFailureError: DescribedS3Error.noSuchUpload
        )
        let resume = MultipartUploader.ResumeContext(
            path: "blob.bin", fileMtime: info.mtime.timeIntervalSince1970, fileSize: info.size, store: ckpt
        )

        let uploader = MultipartUploader(s3: fake, retryPolicy: Self.fastPolicy)
        do {
            _ = try await uploader.upload(key: "files/blob.bin", reader: reader, partSize: 1024, resume: resume)
            XCTFail("失効 MPU の NoSuchUpload は throw すべき")
        } catch let e as DescribedS3Error {
            XCTAssertTrue(e.description.contains("NoSuchUpload"))
        }

        // 既存 MPU 再開なので create/begin なし。
        let createCount = await fake.createCount
        let beginCount = await ckpt.beginCount
        XCTAssertEqual(createCount, 0)
        XCTAssertEqual(beginCount, 0)
        // NoSuchUpload は決定的な恒久失敗なのでリトライせず即 throw（part 4 の試行は 1 回だけ）。
        let attempts4 = await fake.attemptsByPart[4]
        XCTAssertEqual(attempts4, 1)
        // checkpoint を破棄して次回フル再開（保持し続けない）。abort はしない（MPU は既に無い）。
        let clearCount = await ckpt.clearCount
        let abortCount = await fake.abortCount
        XCTAssertEqual(clearCount, 1)
        XCTAssertEqual(abortCount, 0)
        let leftover = try await ckpt.loadUpload(path: "blob.bin")
        XCTAssertNil(leftover)
    }
}

// MARK: - フェイク S3 クライアント

private enum FakeS3Error: Error { case injected }

/// `String(describing:)` に任意のコード文字列を載せられるエラー。`S3ErrorClassifier` が
/// 文字列マッチで分類するので、NoSuchUpload 等の S3 エラーを注入するのに使う。
private struct DescribedS3Error: Error, CustomStringConvertible {
    let description: String
    static let noSuchUpload = DescribedS3Error(
        description: "NoSuchUpload(message: \"The specified multipart upload does not exist.\")"
    )
}

/// `MultipartUploadClient` のテスト用フェイク。並行 `uploadPart` を actor で安全に記録し、
/// パート単位の失敗注入（一時/恒久）に対応する。
private actor FakeMultipartClient: MultipartUploadClient {
    let uploadId: String
    let completeResult: TideS3Client.PutObjectResult

    private(set) var createCount = 0
    private(set) var lastCreateKey: String?
    private(set) var lastCreateMetadata: [String: String] = [:]
    private(set) var bodies: [Int: Data] = [:]            // partNumber -> 受領した本体
    private(set) var attemptsByPart: [Int: Int] = [:]     // partNumber -> 試行回数
    private(set) var completedParts: [(partNumber: Int, etag: String)]?
    private(set) var abortCount = 0
    private(set) var abortedUploadIds: [String] = []
    private(set) var headCount = 0
    private(set) var lastHeadKey: String?

    private var failuresByPart: [Int: Int]                // partNumber -> 残り失敗回数（一時障害）
    private let alwaysFailParts: Set<Int>                 // 恒久失敗
    private let partFailureError: Error                   // 上記失敗時に投げるエラー（既定 .injected）
    private let completeError: Error?                     // complete を強制失敗させる（stale UploadId 模擬）
    private let headResult: TideS3Client.ObjectHead?      // headObject の返値（stale 復旧の検証用）

    init(
        uploadId: String = "upload-id-xyz",
        completeResult: TideS3Client.PutObjectResult = .init(etag: "complete-etag", versionId: "v1"),
        failuresByPart: [Int: Int] = [:],
        alwaysFailParts: Set<Int> = [],
        partFailureError: Error = FakeS3Error.injected,
        completeError: Error? = nil,
        headResult: TideS3Client.ObjectHead? = nil
    ) {
        self.uploadId = uploadId
        self.completeResult = completeResult
        self.failuresByPart = failuresByPart
        self.alwaysFailParts = alwaysFailParts
        self.partFailureError = partFailureError
        self.completeError = completeError
        self.headResult = headResult
    }

    func createMultipartUpload(key: String, contentType: String, metadata: [String: String]) async throws -> String {
        createCount += 1
        lastCreateKey = key
        lastCreateMetadata = metadata
        return uploadId
    }

    func uploadPart(key: String, uploadId: String, partNumber: Int, body: Data) async throws -> String {
        attemptsByPart[partNumber, default: 0] += 1
        if alwaysFailParts.contains(partNumber) {
            throw partFailureError
        }
        if let remaining = failuresByPart[partNumber], remaining > 0 {
            failuresByPart[partNumber] = remaining - 1
            throw partFailureError
        }
        bodies[partNumber] = body
        return "etag-\(partNumber)"
    }

    func completeMultipartUpload(key: String, uploadId: String, parts: [(partNumber: Int, etag: String)]) async throws -> TideS3Client.PutObjectResult {
        completedParts = parts
        if let completeError { throw completeError }
        return completeResult
    }

    func abortMultipartUpload(key: String, uploadId: String) async throws {
        abortCount += 1
        abortedUploadIds.append(uploadId)
    }

    func headObject(key: String, versionId: String?) async throws -> TideS3Client.ObjectHead? {
        headCount += 1
        lastHeadKey = key
        return headResult
    }
}

// MARK: - フェイク checkpoint ストア（中断・再開）

/// `UploadCheckpointStore` のテスト用フェイク。seed で再開状態を仕込める。
private actor FakeUploadCheckpointStore: UploadCheckpointStore {
    private(set) var states: [String: UploadResumeState]
    private(set) var beginCount = 0
    private(set) var clearCount = 0
    private(set) var recordedParts: [String: [CompletedPart]] = [:]

    init(seed: [String: UploadResumeState] = [:]) {
        self.states = seed
    }

    func loadUpload(path: String) async throws -> UploadResumeState? {
        states[path]
    }

    func beginUpload(path: String, uploadId: String, partSize: Int, fileMtime: Double, fileSize: Int64) async throws {
        beginCount += 1
        states[path] = UploadResumeState(
            uploadId: uploadId, partSize: partSize, completedParts: [],
            fileMtime: fileMtime, fileSize: fileSize
        )
    }

    func recordCompletedPart(path: String, part: CompletedPart) async throws {
        recordedParts[path, default: []].append(part)
        if var s = states[path] {
            if !s.completedParts.contains(where: { $0.n == part.n }) {
                s.completedParts.append(part)
            }
            states[path] = s
        }
    }

    func clearUpload(path: String) async throws {
        clearCount += 1
        states[path] = nil
    }
}
