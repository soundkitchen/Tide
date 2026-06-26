import XCTest
import GRDB
@testable import Tide

/// リモート pull の取り込み配線（D1 / #30）。`SyncEngine.reconcileRemoteEntry`（nonisolated static）を
/// フェイク S3 ストリーミング + 実 temp DB で直接駆動し、`ThreeWayMerge.decide` の各分岐 → 実 I/O
/// （download / markSynced / renameLocalForConflict + 通知）の switch マッピングと、入口の reconcileIsNoop
/// ゲート・除外スキップ・不正パスリジェクトを固定する。Issue #25 / A の `UploaderConflictTests` と同型。
///
/// 注記: ここで駆動するのは static 本体まで。@MainActor ラッパ（notifier への Task ディスパッチ・
/// recentIssues への append）は @MainActor private で直接駆動面がないため、注入クロージャのスパイで
/// 「呼ばれたこと」を確認する。
final class ReconcileWiringTests: XCTestCase {

    /// postConflictCopy（@Sendable・非 async）の同期スパイ。
    private final class ConflictCopySpy: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [(path: String, copy: String)] = []
        func record(_ path: String, _ copy: String) { lock.lock(); _calls.append((path, copy)); lock.unlock() }
        var calls: [(path: String, copy: String)] { lock.lock(); defer { lock.unlock() }; return _calls }
    }

    /// recordIssue（@Sendable async）のスパイ。記録した SyncIssue を保持する。
    private actor IssueSpy {
        private(set) var issues: [SyncIssue] = []
        func record(_ issue: SyncIssue) { issues.append(issue) }
    }

    private func makeEnv() throws -> (db: LocalDatabase, store: TransferStateStore, root: URL, tmp: URL) {
        let e = try makeTideTestEnv(prefix: "tide-reconcile-wiring")
        return (e.db, e.store, e.root, e.tmp)
    }

    private func makeDownloader(client: any RangedDownloadClient, env: (db: LocalDatabase, store: TransferStateStore, root: URL, tmp: URL)) -> Downloader {
        makeTestDownloader(client: client, db: env.db, syncRoot: env.root, tmpDir: env.tmp, store: env.store)
    }

    private func remoteEntry(for data: Data, versionId: String = "ver-remote", etag: String = "etag-remote") -> ManifestFileEntry {
        ManifestFileEntry(
            size: Int64(data.count), mtime: "2026-06-10T00:00:00Z", sha256: TestData.shaHex(data),
            s3VersionId: versionId, etag: etag, deviceId: "devR", uploadedAt: "2026-06-10T00:00:00Z"
        )
    }

    private func setMtime(_ url: URL, _ t: Double) throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: t)], ofItemAtPath: url.path)
    }

    /// reconcileRemoteEntry の static 本体を共通引数で駆動する。
    private func reconcile(
        path: String, entry: ManifestFileEntry, dl: Downloader,
        env: (db: LocalDatabase, store: TransferStateStore, root: URL, tmp: URL),
        matcher: LayeredSyncIgnore = .empty, copySpy: ConflictCopySpy, issueSpy: IssueSpy
    ) async {
        await SyncEngine.reconcileRemoteEntry(
            path: path, entry: entry, dl: dl,
            db: env.db, syncRoot: env.root, matcher: matcher,
            postConflictCopy: { p, c in copySpy.record(p, c) },
            recordIssue: { issue, _ in await issueSpy.record(issue) }
        )
    }

    // MARK: - .download

    func testDownloadWhenLocalAbsent() async throws {
        let env = try makeEnv()
        let path = "docs/new.txt"
        let remoteBytes = TestData.deterministicBytes(1500, salt: 1)
        let entry = remoteEntry(for: remoteBytes)
        let fake = FakeRangedDownloadClient(fullData: remoteBytes, etag: entry.etag)
        let copySpy = ConflictCopySpy(); let issueSpy = IssueSpy()

        await reconcile(path: path, entry: entry, dl: makeDownloader(client: fake, env: env), env: env, copySpy: copySpy, issueSpy: issueSpy)

        XCTAssertEqual(fake.callCount, 1, "ローカル欠落 → リモートを取得")
        let url = env.root.appendingPathComponent(path)
        XCTAssertEqual(try Data(contentsOf: url), remoteBytes, "リモート内容が書き込まれる")
        let rec = try await fetchFileRecord(env.db, path: path)
        XCTAssertEqual(rec?.sha256, TestData.shaHex(remoteBytes), "FileRecord がリモート identity を反映")
        let copyCalls = copySpy.calls
        XCTAssertTrue(copyCalls.isEmpty, "download 分岐は衝突通知しない")
    }

    func testDownloadWhenLocalUnchangedRemoteChanged() async throws {
        let env = try makeEnv()
        let path = "report.bin"
        let baseBytes = TestData.deterministicBytes(900, salt: 2)
        let remoteBytes = TestData.deterministicBytes(1100, salt: 3)   // 別内容・別サイズ
        let url = try writeFile(env.root, path, baseBytes)
        try await seedFileRecord(env.db, path: path, sha: TestData.shaHex(baseBytes), size: Int64(baseBytes.count))
        let entry = remoteEntry(for: remoteBytes)
        let fake = FakeRangedDownloadClient(fullData: remoteBytes, etag: entry.etag)
        let copySpy = ConflictCopySpy(); let issueSpy = IssueSpy()

        await reconcile(path: path, entry: entry, dl: makeDownloader(client: fake, env: env), env: env, copySpy: copySpy, issueSpy: issueSpy)

        XCTAssertEqual(fake.callCount, 1, "ローカル未編集・リモート変化 → 上書き取得（reconcileIsNoop は外れる）")
        XCTAssertEqual(try Data(contentsOf: url), remoteBytes)
        XCTAssertTrue(copySpy.calls.isEmpty)
    }

    // MARK: - .localMatchesRemote（download せず markSynced）

    func testLocalMatchesRemoteDoesNotDownload() async throws {
        let env = try makeEnv()
        let path = "shared.txt"
        let bytes = TestData.deterministicBytes(700, salt: 4)
        let url = try writeFile(env.root, path, bytes)
        let fileMtime = 1_780_000_123.456            // サブ秒精度の実 mtime
        try setMtime(url, fileMtime)
        // DB: 内容は一致（sha 同じ）だが etag が古い → reconcileIsNoop を etag 差で外す。
        try await seedFileRecord(
            env.db, path: path, sha: TestData.shaHex(bytes), size: Int64(bytes.count),
            mtime: fileMtime, etag: "etag-old", versionId: "ver-old"
        )
        let entry = remoteEntry(for: bytes, versionId: "ver-remote", etag: "etag-remote")
        let fake = FakeRangedDownloadClient(fullData: bytes, etag: entry.etag)
        let copySpy = ConflictCopySpy(); let issueSpy = IssueSpy()

        await reconcile(path: path, entry: entry, dl: makeDownloader(client: fake, env: env), env: env, copySpy: copySpy, issueSpy: issueSpy)

        XCTAssertEqual(fake.callCount, 0, "内容一致は download せず markSynced のみ")
        XCTAssertEqual(try Data(contentsOf: url), bytes, "ファイルは無変更")
        let rec = try await fetchFileRecord(env.db, path: path)
        XCTAssertEqual(rec?.s3Etag, "etag-remote", "DB の etag がリモートへ追従")
        XCTAssertEqual(rec?.s3VersionId, "ver-remote", "DB の versionId がリモートへ追従")
        // markSynced はローカル stat 実値を mtime に記録（マニフェスト秒精度で上書きしない＝毎起動再 UL 防止）。
        let statMtime = try XCTUnwrap(SyncEngine.statSizeAndMtime(at: url)?.mtime)
        XCTAssertEqual(rec?.mtime ?? 0, statMtime, accuracy: 0.000_01, "DB mtime はローカル stat 実値")
    }

    // MARK: - .conflictThenDownload

    func testConflictThenDownloadWhenLocallyModified() async throws {
        let env = try makeEnv()
        let path = "conflict.bin"
        let baseBytes = TestData.deterministicBytes(640, salt: 5)
        let localBytes = TestData.deterministicBytes(640, salt: 6)     // ローカル編集（base と別）
        let remoteBytes = TestData.deterministicBytes(800, salt: 7)    // リモートも別内容
        try writeFile(env.root, path, localBytes)
        try await seedFileRecord(env.db, path: path, sha: TestData.shaHex(baseBytes), size: Int64(localBytes.count))
        let entry = remoteEntry(for: remoteBytes)
        let fake = FakeRangedDownloadClient(fullData: remoteBytes, etag: entry.etag)
        let copySpy = ConflictCopySpy(); let issueSpy = IssueSpy()

        await reconcile(path: path, entry: entry, dl: makeDownloader(client: fake, env: env), env: env, copySpy: copySpy, issueSpy: issueSpy)

        let calls = copySpy.calls
        XCTAssertEqual(calls.count, 1, "衝突コピー生成を 1 回通知")
        XCTAssertEqual(calls.first?.path, path)
        let copyRelative = try XCTUnwrap(calls.first?.copy)
        XCTAssertEqual(try Data(contentsOf: env.root.appendingPathComponent(copyRelative)), localBytes, "退避コピーは旧ローカル内容")
        XCTAssertEqual(try Data(contentsOf: env.root.appendingPathComponent(path)), remoteBytes, "正規パスはリモート内容")
        XCTAssertEqual(fake.callCount, 1, "退避後にリモートを取得")
    }

    func testConflictThenDownloadWhenUntracked() async throws {
        let env = try makeEnv()
        let path = "untracked.bin"
        let localBytes = TestData.deterministicBytes(500, salt: 8)
        let remoteBytes = TestData.deterministicBytes(900, salt: 9)
        try writeFile(env.root, path, localBytes)
        // FileRecord を seed しない（base == nil＝未追跡）。
        let entry = remoteEntry(for: remoteBytes)
        let fake = FakeRangedDownloadClient(fullData: remoteBytes, etag: entry.etag)
        let copySpy = ConflictCopySpy(); let issueSpy = IssueSpy()

        await reconcile(path: path, entry: entry, dl: makeDownloader(client: fake, env: env), env: env, copySpy: copySpy, issueSpy: issueSpy)

        let calls = copySpy.calls
        XCTAssertEqual(calls.count, 1, "未追跡で別内容も衝突退避")
        let copyRelative = try XCTUnwrap(calls.first?.copy)
        XCTAssertEqual(try Data(contentsOf: env.root.appendingPathComponent(copyRelative)), localBytes)
        XCTAssertEqual(try Data(contentsOf: env.root.appendingPathComponent(path)), remoteBytes)
        XCTAssertEqual(fake.callCount, 1)
    }

    // MARK: - reconcileIsNoop ゲート（全 I/O スキップ）

    func testReconcileNoopSkipsAllIO() async throws {
        let env = try makeEnv()
        let path = "steady.txt"
        let bytes = TestData.deterministicBytes(333, salt: 10)
        let url = try writeFile(env.root, path, bytes)
        let fileMtime = 1_780_000_200.25
        try setMtime(url, fileMtime)
        let sentinel = 42.0
        // DB がリモート entry を完全反映（sha/etag/versionId 一致）+ ローカルが DB と一致（size/mtime）。
        try await seedFileRecord(
            env.db, path: path, sha: TestData.shaHex(bytes), size: Int64(bytes.count),
            mtime: fileMtime, etag: "etag-remote", versionId: "ver-remote", updatedAt: sentinel
        )
        let entry = remoteEntry(for: bytes, versionId: "ver-remote", etag: "etag-remote")
        let fake = FakeRangedDownloadClient(fullData: bytes, etag: entry.etag)
        let copySpy = ConflictCopySpy(); let issueSpy = IssueSpy()

        await reconcile(path: path, entry: entry, dl: makeDownloader(client: fake, env: env), env: env, copySpy: copySpy, issueSpy: issueSpy)

        XCTAssertEqual(fake.callCount, 0, "証明可能な no-op は download しない")
        let rec = try await fetchFileRecord(env.db, path: path)
        XCTAssertEqual(rec?.updatedAt, sentinel, "no-op は DB write もしない（updatedAt 不変）")
    }

    // MARK: - 除外スキップ

    func testIgnoredRemoteEntrySkipped() async throws {
        let env = try makeEnv()
        let path = "ignored.txt"
        let matcher = LayeredSyncIgnore(root: SyncIgnoreMatcher.parse("ignored.txt\n"))
        let entry = remoteEntry(for: TestData.deterministicBytes(100, salt: 11))
        let fake = FakeRangedDownloadClient(fullData: Data())
        let copySpy = ConflictCopySpy(); let issueSpy = IssueSpy()

        await reconcile(path: path, entry: entry, dl: makeDownloader(client: fake, env: env), env: env, matcher: matcher, copySpy: copySpy, issueSpy: issueSpy)

        XCTAssertEqual(fake.callCount, 0, "未追跡の除外対象は取得しない")
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.root.appendingPathComponent(path).path))
    }

    // MARK: - 不正パスリジェクト

    func testUnsafeRemotePathRecordsIssue() async throws {
        let env = try makeEnv()
        let path = "../escape.txt"
        let entry = remoteEntry(for: TestData.deterministicBytes(100, salt: 12))
        let fake = FakeRangedDownloadClient(fullData: Data())
        let copySpy = ConflictCopySpy(); let issueSpy = IssueSpy()

        await reconcile(path: path, entry: entry, dl: makeDownloader(client: fake, env: env), env: env, copySpy: copySpy, issueSpy: issueSpy)

        XCTAssertEqual(fake.callCount, 0, "不正パスは取得しない")
        let issues = await issueSpy.issues
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.category, .unsafePath)
    }
}
