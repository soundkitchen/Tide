import XCTest
import TideCore
@testable import Tide

/// 旧ロケーション → App Group コンテナへの一度きり移行（M5 Phase 2）の注入版を検証する。
final class LegacyStateMigratorTests: XCTestCase {
    private var legacyDir: URL!
    private var groupDir: URL!
    private var legacyDefaults: UserDefaults!
    private var groupDefaults: UserDefaults!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("migrator-tests-\(UUID().uuidString)")
        legacyDir = base.appendingPathComponent("legacy/Tide", isDirectory: true)
        groupDir = base.appendingPathComponent("group/Tide", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)

        let legacySuite = "tide-tests-legacy-\(UUID().uuidString)"
        let groupSuite = "tide-tests-group-\(UUID().uuidString)"
        legacyDefaults = UserDefaults(suiteName: legacySuite)!
        groupDefaults = UserDefaults(suiteName: groupSuite)!
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: legacySuite)
            UserDefaults.standard.removePersistentDomain(forName: groupSuite)
            try? FileManager.default.removeItem(at: base)
        }
    }

    private func runMigration() -> LegacyStateMigrator.Outcome {
        LegacyStateMigrator.migrateIfNeeded(
            legacySupportTideDir: legacyDir,
            legacyDefaults: legacyDefaults,
            groupSupportTideDir: groupDir,
            groupDefaults: groupDefaults
        )
    }

    private func writeLegacyDB(main: String = "main", wal: String? = nil, shm: String? = nil) throws {
        try Data(main.utf8).write(to: legacyDir.appendingPathComponent("db.sqlite"))
        if let wal {
            try Data(wal.utf8).write(to: legacyDir.appendingPathComponent("db.sqlite-wal"))
        }
        if let shm {
            try Data(shm.utf8).write(to: legacyDir.appendingPathComponent("db.sqlite-shm"))
        }
    }

    // MARK: - DB

    func testMigratesDatabaseWithWALAndSHM() throws {
        try writeLegacyDB(main: "main", wal: "wal", shm: "shm")

        let outcome = runMigration()

        XCTAssertTrue(outcome.databaseMigrated)
        XCTAssertEqual(
            try String(contentsOf: groupDir.appendingPathComponent("db.sqlite"), encoding: .utf8),
            "main"
        )
        XCTAssertEqual(
            try String(contentsOf: groupDir.appendingPathComponent("db.sqlite-wal"), encoding: .utf8),
            "wal"
        )
        XCTAssertEqual(
            try String(contentsOf: groupDir.appendingPathComponent("db.sqlite-shm"), encoding: .utf8),
            "shm"
        )
        // 旧ファイルは温存（データ損失 < 重複）
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyDir.appendingPathComponent("db.sqlite").path))
    }

    func testMigratesDatabaseWithoutWAL() throws {
        try writeLegacyDB(main: "main-only")

        let outcome = runMigration()

        XCTAssertTrue(outcome.databaseMigrated)
        XCTAssertEqual(
            try String(contentsOf: groupDir.appendingPathComponent("db.sqlite"), encoding: .utf8),
            "main-only"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: groupDir.appendingPathComponent("db.sqlite-wal").path))
    }

    func testDoesNotOverwriteExistingGroupDatabase() throws {
        try writeLegacyDB(main: "legacy")
        try FileManager.default.createDirectory(at: groupDir, withIntermediateDirectories: true)
        try Data("already-migrated".utf8).write(to: groupDir.appendingPathComponent("db.sqlite"))

        let outcome = runMigration()

        XCTAssertFalse(outcome.databaseMigrated)
        XCTAssertEqual(
            try String(contentsOf: groupDir.appendingPathComponent("db.sqlite"), encoding: .utf8),
            "already-migrated"
        )
    }

    func testRetriesAfterPartialCopy() throws {
        // 途中クラッシュ相当: WAL だけ移行先に残っている（本体 db.sqlite は無い）状態から
        // 再実行しても、removeItem → copyItem で頭から安全にやり直せる。
        try writeLegacyDB(main: "main", wal: "fresh-wal")
        try FileManager.default.createDirectory(at: groupDir, withIntermediateDirectories: true)
        try Data("stale-wal".utf8).write(to: groupDir.appendingPathComponent("db.sqlite-wal"))

        let outcome = runMigration()

        XCTAssertTrue(outcome.databaseMigrated)
        XCTAssertEqual(
            try String(contentsOf: groupDir.appendingPathComponent("db.sqlite-wal"), encoding: .utf8),
            "fresh-wal"
        )
    }

    func testNoLegacyDatabaseIsNoop() {
        let outcome = runMigration()
        XCTAssertFalse(outcome.databaseMigrated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: groupDir.appendingPathComponent("db.sqlite").path))
    }

    // MARK: - Config

    func testMigratesConfigWhenLegacySetupCompleted() throws {
        try writeLegacyDB()
        let legacy = ConfigStore(defaults: legacyDefaults)
        legacy.bucketName = "legacy-bucket"
        legacy.region = "ap-northeast-1"
        legacy.syncRootPath = "/Users/x/Tide"
        legacy.setupCompleted = true
        let legacyDeviceId = legacy.deviceId

        let outcome = runMigration()

        XCTAssertTrue(outcome.configMigrated)
        let group = ConfigStore(defaults: groupDefaults)
        XCTAssertEqual(group.bucketName, "legacy-bucket")
        XCTAssertEqual(group.region, "ap-northeast-1")
        XCTAssertEqual(group.syncRootPath, "/Users/x/Tide")
        XCTAssertTrue(group.setupCompleted)
        // deviceId（マニフェスト上のデバイス識別）を引き継ぐ
        XCTAssertEqual(group.deviceId, legacyDeviceId)
    }

    func testDoesNotMigrateConfigWhenGroupAlreadySetUp() throws {
        try writeLegacyDB()
        let legacy = ConfigStore(defaults: legacyDefaults)
        legacy.bucketName = "legacy-bucket"
        legacy.setupCompleted = true
        let group = ConfigStore(defaults: groupDefaults)
        group.bucketName = "group-bucket"
        group.setupCompleted = true

        let outcome = runMigration()

        XCTAssertFalse(outcome.configMigrated)
        XCTAssertEqual(group.bucketName, "group-bucket")
    }

    func testDoesNotMigrateConfigWhenLegacySetupIncomplete() throws {
        // 旧側にキーはあるがセットアップ未完了 → 移すべき確定状態が無いので no-op
        try writeLegacyDB()
        let legacy = ConfigStore(defaults: legacyDefaults)
        legacy.bucketName = "half-configured"

        let outcome = runMigration()

        XCTAssertFalse(outcome.configMigrated)
        XCTAssertNil(ConfigStore(defaults: groupDefaults).bucketName)
    }

    // MARK: - Config は legacy DB の実在でゲート（PR #49 レビュー #1/#4）

    func testDoesNotMigrateConfigWithoutLegacyDatabase() {
        // 一足飛びアップグレード相当: macOS が旧 preferences plist をコンテナへ自動移行するため
        // 「旧設定だけが見える」が、legacy DB は sandbox で見えない。config-only 移行を許すと
        // 「設定あり・DB 空」で起動して全量再アップロードに至るので、移行しないこと。
        let legacy = ConfigStore(defaults: legacyDefaults)
        legacy.bucketName = "legacy-bucket"
        legacy.setupCompleted = true

        let outcome = runMigration()

        XCTAssertFalse(outcome.databaseMigrated)
        XCTAssertFalse(outcome.configMigrated)
        let group = ConfigStore(defaults: groupDefaults)
        XCTAssertNil(group.bucketName)
        XCTAssertFalse(group.setupCompleted)
    }

    func testSkipsConfigMigrationWhenDatabaseCopyFailsAndRetriesNextRun() throws {
        // DB コピー失敗の回に設定だけ移行すると、bootstrap がそのまま launchEngine へ進んで
        // group パスに空 DB を生成し冪等キーを汚す（DB 移行リトライが永久に潰れる）。
        // 設定移行ごとスキップし、次回起動で両方とも頭からやり直せること。
        try writeLegacyDB(main: "main")
        let legacyDBURL = legacyDir.appendingPathComponent("db.sqlite")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: legacyDBURL.path)
        let legacy = ConfigStore(defaults: legacyDefaults)
        legacy.bucketName = "legacy-bucket"
        legacy.setupCompleted = true

        let failed = runMigration()

        XCTAssertFalse(failed.databaseMigrated)
        XCTAssertFalse(failed.configMigrated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: groupDir.appendingPathComponent("db.sqlite").path))
        XCTAssertFalse(ConfigStore(defaults: groupDefaults).setupCompleted)

        // 原因解消後の次回起動 → 両方とも移行される
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: legacyDBURL.path)
        let retried = runMigration()

        XCTAssertTrue(retried.databaseMigrated)
        XCTAssertTrue(retried.configMigrated)
        XCTAssertEqual(ConfigStore(defaults: groupDefaults).bucketName, "legacy-bucket")
    }

    // MARK: - 複数移行元の連鎖（Phase 3: 旧 group コンテナ → 実ホームの 2 世代）

    func testFirstLegacySourceWithDatabaseWins() throws {
        // 先頭（新しい世代＝旧 group コンテナ相当）が勝ち、2 つ目は冪等ゲートで no-op になる
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("migrator-chain-\(UUID().uuidString)")
        let newerDir = base.appendingPathComponent("newer/Tide", isDirectory: true)
        let olderDir = base.appendingPathComponent("older/Tide", isDirectory: true)
        try FileManager.default.createDirectory(at: newerDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: olderDir, withIntermediateDirectories: true)
        try Data("new-gen".utf8).write(to: newerDir.appendingPathComponent("db.sqlite"))
        try Data("old-gen".utf8).write(to: olderDir.appendingPathComponent("db.sqlite"))
        let newerSuite = "tide-tests-newer-\(UUID().uuidString)"
        let olderSuite = "tide-tests-older-\(UUID().uuidString)"
        let newerDefaults = UserDefaults(suiteName: newerSuite)!
        let olderDefaults = UserDefaults(suiteName: olderSuite)!
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: newerSuite)
            UserDefaults.standard.removePersistentDomain(forName: olderSuite)
            try? FileManager.default.removeItem(at: base)
        }
        let newer = ConfigStore(defaults: newerDefaults)
        newer.bucketName = "bucket-newer"
        newer.setupCompleted = true
        let older = ConfigStore(defaults: olderDefaults)
        older.bucketName = "bucket-older"
        older.setupCompleted = true

        let outcome = LegacyStateMigrator.migrateIfNeeded(
            legacySources: [
                .init(supportTideDir: newerDir, defaults: newerDefaults),
                .init(supportTideDir: olderDir, defaults: olderDefaults),
            ],
            groupSupportTideDir: groupDir,
            groupDefaults: groupDefaults
        )

        XCTAssertTrue(outcome.databaseMigrated)
        XCTAssertTrue(outcome.configMigrated)
        XCTAssertEqual(
            try String(contentsOf: groupDir.appendingPathComponent("db.sqlite"), encoding: .utf8),
            "new-gen"
        )
        XCTAssertEqual(ConfigStore(defaults: groupDefaults).bucketName, "bucket-newer")
    }

    func testMigratesConfigWhenGroupDatabaseAlreadyMigrated() throws {
        // 前回起動で DB だけ移行済み（config 移行前にクラッシュ等）→ 今回は config だけ移行される
        try writeLegacyDB(main: "legacy")
        try FileManager.default.createDirectory(at: groupDir, withIntermediateDirectories: true)
        try Data("already-migrated".utf8).write(to: groupDir.appendingPathComponent("db.sqlite"))
        let legacy = ConfigStore(defaults: legacyDefaults)
        legacy.bucketName = "legacy-bucket"
        legacy.setupCompleted = true

        let outcome = runMigration()

        XCTAssertFalse(outcome.databaseMigrated)
        XCTAssertTrue(outcome.configMigrated)
        XCTAssertEqual(ConfigStore(defaults: groupDefaults).bucketName, "legacy-bucket")
    }
}
