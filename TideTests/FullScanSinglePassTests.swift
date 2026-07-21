import XCTest
import GRDB
import TideCore
@testable import Tide

/// Issue #64: 単一走査フルスキャン（`walkSyncTree` / `classifyAndEnqueue` / 合成 `singlePassScan`）の
/// 直接駆動テスト。
///
/// 旧 flat 実装ではツリー走査本体が @MainActor クロージャ内にあり直接駆動面が無かった
/// （docs/09 の残ギャップ）。#64 の再帰下降化で走査本体を nonisolated static + 依存注入へ
/// 切り出したため、ここで「dir の `.syncignore` を配下ファイル評価より先に読む」という
/// 単一走査化の核心と、走査副産物（層辞書）・機密網 subtree スキップ・maxFiles 上限の
/// 走査継続・列挙失敗時の fail-safe（root = 中断 / 配下 dir = subtree skip + 削除検出抑止・
/// PR #74 レビュー高 2）・非 regular file ゲート（FIFO・同高 1）を直接固定する。
/// symlink 非追従の終端不変条件は既存の `FullScanSymlinkTests`（エンジン経由）が引き続き担う。
final class FullScanSinglePassTests: XCTestCase {

    private func runScan(
        root: URL, db: LocalDatabase
    ) async throws -> (result: SyncEngine.SinglePassScanResult, uploads: Set<String>, deletes: Set<String>) {
        let result = try await SyncEngine.singlePassScan(
            root: root, db: db, now: Date().timeIntervalSince1970
        )
        let rows = try await db.pool.read { db in try UploadQueueRecord.fetchAll(db) }
        return (
            result,
            Set(rows.filter { $0.operation == "upload" }.map(\.path)),
            Set(rows.filter { $0.operation == "delete" }.map(\.path))
        )
    }

    /// 走査副産物: 全 `.syncignore` が層辞書に載る。機密網配下と dir-symlink 先（root 外）の
    /// `.syncignore` は載らない。`.syncignore` 自身は同期対象として upload に乗る（自己保護）。
    func testScanBuildsLayerDictionaryAsByproduct() async throws {
        let env = try makeTideTestEnv(prefix: "tide-scan-64-layers")
        try writeFile(env.root, ".syncignore", Data("*.log\n".utf8))
        try writeFile(env.root, "d1/.syncignore", Data("*.tmp\n".utf8))
        try writeFile(env.root, "d1/a.txt", Data("a".utf8))
        // 機密網: subtree ごと降りない（.syncignore も配下ファイルも載らない）。
        try writeFile(env.root, ".aws/.syncignore", Data("secret-pat\n".utf8))
        try writeFile(env.root, ".aws/config.txt", Data("c".utf8))
        // dir-symlink: root 外の .syncignore / ファイルは一切載らない（C2）。
        let outside = env.base.appendingPathComponent("outside", isDirectory: true)
        try writeFile(outside, ".syncignore", Data("outside-pat\n".utf8))
        try writeFile(outside, "secret.txt", Data("s".utf8))
        try FileManager.default.createSymbolicLink(
            at: env.root.appendingPathComponent("linkdir"), withDestinationURL: outside
        )

        let (result, uploads, deletes) = try await runScan(root: env.root, db: env.db)

        XCTAssertEqual(result.ignoreMatcher.directoryGroups.map(\.directory), ["", "d1"])
        XCTAssertTrue(uploads.contains(".syncignore"))
        XCTAssertTrue(uploads.contains("d1/.syncignore"))
        XCTAssertTrue(uploads.contains("d1/a.txt"))
        XCTAssertTrue(
            uploads.allSatisfy { !$0.hasPrefix(".aws/") && !$0.hasPrefix("linkdir/") },
            "機密網 / dir-symlink 配下が走査に乗っている: \(uploads)"
        )
        XCTAssertTrue(deletes.isEmpty)
    }

    /// 単一走査化の核心: 進入時に読んだ dir の `.syncignore` が**同じ走査内で**配下の
    /// 未追跡ファイルへ適用される（先行 discovery 走査なしで除外が効く）。
    /// 既存追跡はパターンにマッチしても触らない（未追跡のみ・foundPaths に載って delete も出ない）。
    func testLayerReadInSamePassAppliesToDescendants() async throws {
        let env = try makeTideTestEnv(prefix: "tide-scan-64-samepass")
        try writeFile(env.root, ".syncignore", Data("*.log\n".utf8))
        try writeFile(env.root, "logs/app.log", Data("x".utf8))       // 未追跡 → 除外
        try writeFile(env.root, "logs/keep.txt", Data("k".utf8))      // 未追跡・非マッチ → enqueue
        try writeFile(env.root, "logs/tracked.log", Data("t".utf8))   // 追跡済み → 除外しない
        try await seedFileRecord(env.db, path: "logs/tracked.log", sha: "stale", size: 1)

        let (_, uploads, deletes) = try await runScan(root: env.root, db: env.db)

        XCTAssertFalse(uploads.contains("logs/app.log"), "未追跡の除外対象が同一走査内で除外されていない")
        XCTAssertTrue(uploads.contains("logs/keep.txt"))
        XCTAssertTrue(uploads.contains("logs/tracked.log"), "既存追跡がユーザパターンで除外された")
        XCTAssertTrue(deletes.isEmpty, "追跡ファイルが削除検出に乗った: \(deletes)")
    }

    /// 層合成: 深い層の再包含（`!pattern`）が浅い層の除外を同一走査内で上書きする
    /// （浅い→深い last-match-wins・`LayeredSyncIgnore` の評価規則が走査文脈でも効く）。
    func testDeeperLayerOverridesShallowerWithinSamePass() async throws {
        let env = try makeTideTestEnv(prefix: "tide-scan-64-layered")
        try writeFile(env.root, ".syncignore", Data("*.log\n".utf8))
        try writeFile(env.root, "d/.syncignore", Data("!keep.log\n".utf8))
        try writeFile(env.root, "top.log", Data("1".utf8))
        try writeFile(env.root, "d/drop.log", Data("2".utf8))
        try writeFile(env.root, "d/keep.log", Data("3".utf8))

        let (_, uploads, _) = try await runScan(root: env.root, db: env.db)

        XCTAssertFalse(uploads.contains("top.log"))
        XCTAssertFalse(uploads.contains("d/drop.log"))
        XCTAssertTrue(uploads.contains("d/keep.log"), "深い層の再包含が効いていない")
    }

    /// maxFiles 上限: 層の追加は上限で打ち切るが、**走査自体は最後まで続ける**（旧 discovery の
    /// break と違い、scan は削除検出の正しさのため全域走査が必須）。
    func testMaxFilesCapStopsLayersButNotScan() async throws {
        let env = try makeTideTestEnv(prefix: "tide-scan-64-cap")
        let total = LayeredSyncIgnore.maxFiles + 2
        for i in 0..<total {
            let dir = String(format: "d%04d", i)
            try writeFile(env.root, "\(dir)/.syncignore", Data("pat\n".utf8))
            try writeFile(env.root, "\(dir)/child.txt", Data("c".utf8))
        }

        let (result, uploads, _) = try await runScan(root: env.root, db: env.db)

        XCTAssertEqual(result.ignoreMatcher.fileCount, LayeredSyncIgnore.maxFiles)
        for i in 0..<total {
            let p = String(format: "d%04d/child.txt", i)
            XCTAssertTrue(uploads.contains(p), "\(p) が走査から欠落（上限到達で走査が打ち切られた）")
        }
    }

    /// fail-safe（PR #74 レビュー高 2）: 子列挙に失敗した配下 dir は **subtree のみ skip** して走査を
    /// 続行し、**削除検出だけを抑止**する。upload / mtime 修復 / 層辞書構築は継続する
    /// （旧 enumerator は黙って skip ＝配下の追跡ファイルが誤 delete に乗り得た。全体中断だと
    /// 読めない dir が 1 個あるだけで upload と層辞書 publish まで全滅し、`.syncignore` 除外が
    /// event 経路で恒久無効化する）。
    func testUnreadableSubdirectorySkipsSubtreeAndSuppressesDeletionsOnly() async throws {
        let env = try makeTideTestEnv(prefix: "tide-scan-64-eperm")
        try writeFile(env.root, ".syncignore", Data("*.log\n".utf8))
        try writeFile(env.root, "ok.txt", Data("o".utf8))
        try writeFile(env.root, "locked/inner.txt", Data("i".utf8))
        // 実在しない追跡行: 削除検出が抑止されなければ delete が enqueue されてしまう。
        try await seedFileRecord(env.db, path: "gone.txt", sha: "stale", size: 1)
        let locked = env.root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        }

        let (result, uploads, deletes) = try await runScan(root: env.root, db: env.db)

        XCTAssertEqual(result.unreadableDirs, ["locked"])
        XCTAssertTrue(result.scanIncomplete)
        XCTAssertTrue(deletes.isEmpty, "走査不完全なのに削除検出が走った（誤 delete の危険）: \(deletes)")
        XCTAssertEqual(result.deletedEnqueued, 0)
        // upload と層辞書は巻き添えにしない。
        XCTAssertTrue(uploads.contains("ok.txt"), "列挙不能 dir の巻き添えで upload が止まった")
        XCTAssertEqual(result.ignoreMatcher.directoryGroups.map(\.directory), [""])
    }

    /// fail-safe（root）: syncRoot 自体が列挙不能ならスキャン全体を中断し、**削除検出まで進まない**
    /// （旧 enumerator は黙って空を返し、foundPaths 空のまま削除検出へ進んで全ファイル誤 delete し得た）。
    func testRootEnumerationFailureAbortsWithoutDeletions() async throws {
        let env = try makeTideTestEnv(prefix: "tide-scan-64-rooteperm")
        try writeFile(env.root, "a.txt", Data("a".utf8))
        try await seedFileRecord(env.db, path: "a.txt", sha: "stale", size: 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: env.root.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: env.root.path)
        }

        do {
            _ = try await SyncEngine.singlePassScan(
                root: env.root, db: env.db, now: Date().timeIntervalSince1970
            )
            XCTFail("syncRoot が列挙不能なのに走査が成功した")
        } catch {
            // 期待どおり中断
        }
        let rows = try await env.db.pool.read { db in try UploadQueueRecord.fetchAll(db) }
        XCTAssertTrue(rows.isEmpty, "中断したスキャンが enqueue を残した（誤 delete の危険）: \(rows.map(\.path))")
    }

    /// 非 regular file ゲート（PR #74 レビュー高 1）: FIFO の `.syncignore` を open 前に拒否する。
    /// 旧実装は `isRegularFile` ガードで守れていたが、共通実装 `readSyncignoreLayer` の初版で
    /// 欠落した（FIFO を `Data(contentsOf:)` すると書き手待ちで永久ブロック → `isFullScanning` が
    /// 解放されず以後の全スキャンが再起動まで停止する）。回帰時はこのテストがハングして検出される。
    func testFifoSyncignoreDoesNotBlockScan() async throws {
        let env = try makeTideTestEnv(prefix: "tide-scan-64-fifo")
        try writeFile(env.root, "ok.txt", Data("o".utf8))
        let fifoPath = env.root.appendingPathComponent(".syncignore").path
        guard mkfifo(fifoPath, 0o644) == 0 else {
            return XCTFail("mkfifo failed: errno=\(errno)")
        }

        let (result, uploads, _) = try await runScan(root: env.root, db: env.db)

        XCTAssertTrue(result.ignoreMatcher.directoryGroups.isEmpty, "FIFO の .syncignore が層に載った")
        XCTAssertTrue(uploads.contains("ok.txt"))
        // FIFO 自身は regular file でないので同期対象に乗らない（旧実装と同じ）。
        XCTAssertFalse(uploads.contains(".syncignore"), "FIFO がアップロード対象に乗った")
    }

    /// `readSyncignoreLayer` の正規化（PR #74 レビュー nit 5）: 空パターン（コメントのみ）は
    /// nil = 層なしへ正規化する（patch 側の「新規層の追加」maxFiles ガードが除去相当の patch を
    /// 誤スキップしない。全再構築でも空層は init が落とすため意味論は同値）。
    func testReadSyncignoreLayerNormalizesEmptyToNil() throws {
        let env = try makeTideTestEnv(prefix: "tide-scan-64-empty")
        try writeFile(env.root, ".syncignore", Data("# comment only\n\n".utf8))
        XCTAssertNil(SyncEngine.readSyncignoreLayer(relativePath: ".syncignore", syncRoot: env.root))
        try writeFile(env.root, ".syncignore", Data("*.log\n".utf8))
        XCTAssertNotNil(SyncEngine.readSyncignoreLayer(relativePath: ".syncignore", syncRoot: env.root))
    }

    /// 2 フェーズ分割（PR #74 レビュー中 3）: 走査フェーズ（`walkSyncTree`）単体で層辞書と対象
    /// ファイル収集が完成する＝DB 接触（per-file read / hash）を伴う分類フェーズを待たずに
    /// `performFullScan` が層辞書を publish できることの直接固定。
    func testWalkPhaseCompletesLayerDictionaryWithoutDatabase() throws {
        let env = try makeTideTestEnv(prefix: "tide-scan-64-walk")
        try writeFile(env.root, ".syncignore", Data("*.log\n".utf8))
        try writeFile(env.root, "d1/.syncignore", Data("*.tmp\n".utf8))
        try writeFile(env.root, "d1/a.txt", Data("a".utf8))
        try writeFile(env.root, "b.log", Data("b".utf8))

        let walk = try SyncEngine.walkSyncTree(root: env.root)

        XCTAssertEqual(walk.ignoreMatcher.directoryGroups.map(\.directory), ["", "d1"])
        // 収集はユーザパターン評価前（未追跡判定に DB が要るため分類フェーズの管轄）＝全対象が載る。
        let relatives = Set(walk.files.map(\.relative))
        XCTAssertEqual(relatives, [".syncignore", "d1/.syncignore", "d1/a.txt", "b.log"])
        XCTAssertFalse(walk.scanIncomplete)
    }
}
