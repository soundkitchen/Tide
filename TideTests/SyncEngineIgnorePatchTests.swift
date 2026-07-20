import XCTest
import GRDB
import TideCore
@testable import Tide

/// Issue #64: `.syncignore` インプレース patch（`patchIgnoreLayer`）と scan 完了時 publish
/// （`publishScanIgnoreMatcher` の世代ガード）のエンジン側配線テスト。
///
/// patch は「保存直後〜scan 完了までの後続イベントが旧 matcher で評価される窓」を閉じる
/// （例: ビルド中に `build/` を追記 → 窓中の生成物が upload され恒久追跡化する事故の防止）。
/// SyncEngine は実物を構築する（init / scan は S3 へ出ない＝ダミー資格情報で安全）。
@MainActor
final class SyncEngineIgnorePatchTests: XCTestCase {

    private func makeEngine(root: URL, db: LocalDatabase) throws -> SyncEngine {
        let (s3, config) = try makeOfflineS3AndConfig()
        return SyncEngine(db: db, s3: s3, syncRoot: root, deviceId: "devT", config: config)
    }

    /// triggerFullScan 単体で層辞書が publish される（起動経路の先行 reloadIgnoreMatcher 撤去後も
    /// Settings 表示・評価用 matcher が走査 1 回で立つ＝#64 の完了条件）。
    func testTriggerFullScanPublishesLayerDictionary() async throws {
        let env = try makeTideTestEnv(prefix: "tide-64-scanpub")
        try writeFile(env.root, ".syncignore", Data("*.log\n".utf8))
        try writeFile(env.root, "d1/.syncignore", Data("*.tmp\n".utf8))
        let engine = try makeEngine(root: env.root, db: env.db)

        XCTAssertTrue(engine.activeIgnorePatterns.isEmpty)
        await engine.triggerFullScan()

        XCTAssertEqual(engine.activeIgnorePatterns.map(\.directory), ["", "d1"])
        XCTAssertEqual(engine.activeIgnorePatterns.first?.patterns, ["*.log"])
    }

    /// patch の追加 → 更新 → 除去がツリー走査なしで matcher / Settings 表示へ反映される。
    func testPatchIgnoreLayerAddUpdateRemove() async throws {
        let env = try makeTideTestEnv(prefix: "tide-64-patch")
        let engine = try makeEngine(root: env.root, db: env.db)

        // 追加（ルート層）
        try writeFile(env.root, ".syncignore", Data("*.tmp\n".utf8))
        await engine.patchIgnoreLayer(forSyncignoreAt: ".syncignore")
        XCTAssertEqual(engine.activeIgnorePatterns.map(\.directory), [""])
        XCTAssertEqual(engine.activeIgnorePatterns.first?.patterns, ["*.tmp"])

        // 追加（ネスト層）
        try writeFile(env.root, "d/.syncignore", Data("*.bak\n".utf8))
        await engine.patchIgnoreLayer(forSyncignoreAt: "d/.syncignore")
        XCTAssertEqual(engine.activeIgnorePatterns.map(\.directory), ["", "d"])

        // 更新（同一層の差し替え）
        try writeFile(env.root, ".syncignore", Data("*.tmp\nbuild/\n".utf8))
        await engine.patchIgnoreLayer(forSyncignoreAt: ".syncignore")
        XCTAssertEqual(engine.activeIgnorePatterns.first?.patterns, ["*.tmp", "build/"])

        // 除去（ファイル削除）
        try FileManager.default.removeItem(at: env.root.appendingPathComponent(".syncignore"))
        await engine.patchIgnoreLayer(forSyncignoreAt: ".syncignore")
        XCTAssertEqual(engine.activeIgnorePatterns.map(\.directory), ["d"])
    }

    /// patch の安全ゲート: symlink の `.syncignore` は読まない（層に載らない・既存層は除去）。
    /// 機密網配下の `.syncignore` も読まない（ゲートで no-op）。
    func testPatchIgnoreLayerRejectsSymlinkAndSecretNet() async throws {
        let env = try makeTideTestEnv(prefix: "tide-64-patchgate")
        let engine = try makeEngine(root: env.root, db: env.db)

        // symlink: root 外の実ファイルを指す .syncignore → 読まれず層は立たない。
        let outside = env.base.appendingPathComponent("outside.syncignore")
        try Data("evil-pat\n".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: env.root.appendingPathComponent(".syncignore"), withDestinationURL: outside
        )
        await engine.patchIgnoreLayer(forSyncignoreAt: ".syncignore")
        XCTAssertTrue(engine.activeIgnorePatterns.isEmpty, "symlink の .syncignore が読まれた")

        // 機密網配下: ゲートで no-op（層に載らない）。
        try writeFile(env.root, ".aws/.syncignore", Data("secret-pat\n".utf8))
        await engine.patchIgnoreLayer(forSyncignoreAt: ".aws/.syncignore")
        XCTAssertTrue(engine.activeIgnorePatterns.isEmpty, "機密網配下の .syncignore が読まれた")
    }

    /// scan 完了時 publish の世代ガード: 走査開始時点から世代が進んでいたら（＝走査中に patch /
    /// reload が挟まったら）走査副産物は stale として捨て、matcher を巻き戻さない。
    func testScanPublishSkippedWhenGenerationAdvanced() async throws {
        let env = try makeTideTestEnv(prefix: "tide-64-generation")
        let engine = try makeEngine(root: env.root, db: env.db)
        let scanProduct = LayeredSyncIgnore(matchers: ["": SyncIgnoreMatcher.parse("*.from-scan")])

        // 世代が進んでいなければ publish される（正常系）。
        let g0 = engine.currentIgnoreGeneration
        engine.publishScanIgnoreMatcher(scanProduct, ifGenerationStillEquals: g0)
        XCTAssertEqual(engine.activeIgnorePatterns.first?.patterns, ["*.from-scan"])

        // 「走査中」に patch が挟まったら（世代が進んだら）、その走査の副産物は捨てられる。
        let g1 = engine.currentIgnoreGeneration
        try writeFile(env.root, ".syncignore", Data("*.from-patch\n".utf8))
        await engine.patchIgnoreLayer(forSyncignoreAt: ".syncignore")
        XCTAssertEqual(engine.activeIgnorePatterns.first?.patterns, ["*.from-patch"])
        engine.publishScanIgnoreMatcher(scanProduct, ifGenerationStillEquals: g1)
        XCTAssertEqual(
            engine.activeIgnorePatterns.first?.patterns, ["*.from-patch"],
            "stale な走査副産物が patch 済み matcher を巻き戻した"
        )

        // 現在世代を渡せば publish される（後続 scan の再構築に相当）。
        engine.publishScanIgnoreMatcher(scanProduct, ifGenerationStillEquals: engine.currentIgnoreGeneration)
        XCTAssertEqual(engine.activeIgnorePatterns.first?.patterns, ["*.from-scan"])
    }
}
