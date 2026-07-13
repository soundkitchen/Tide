import XCTest
import TideCore

/// 実体化バッジ（Issue #65）の純粋判定を固定する。
/// dir チェック基準 = 「配下に 1 ファイル以上あり、かつ配下全ファイルが実体化済み」
/// （2026-07-14 ユーザ確定・空フォルダはチェックなし）。
final class MaterializedBadgeTests: XCTestCase {
    // MARK: - checkedDirectories

    func testCheckedDirectoriesRequiresAllDescendantsMaterialized() {
        let files = ["docs/a.txt", "docs/b.txt", "docs/sub/c.txt", "top.txt"]
        // 一部だけ実体化 → docs はチェックされない（sub は配下全実体化でチェック）
        let partial = MaterializedBadge.checkedDirectories(
            filePaths: files, materialized: ["docs/a.txt", "docs/sub/c.txt"])
        XCTAssertEqual(partial, ["docs/sub"])
        // 全部実体化 → docs / docs/sub の両方（ルート "" は決して含まれない）
        let full = MaterializedBadge.checkedDirectories(
            filePaths: files, materialized: Set(files))
        XCTAssertEqual(full, ["docs", "docs/sub"])
        XCTAssertFalse(full.contains(""))
    }

    /// 配下ファイルゼロの dir はそもそも集計に現れない（空フォルダ = チェックなし）。
    /// 実体化ゼロなら何もチェックされない。
    func testCheckedDirectoriesEmptyCases() {
        XCTAssertEqual(
            MaterializedBadge.checkedDirectories(filePaths: [], materialized: []), [])
        XCTAssertEqual(
            MaterializedBadge.checkedDirectories(
                filePaths: ["docs/a.txt"], materialized: []),
            []
        )
        // materialized に居るがツリーに無いパス（stale）は集計へ影響しない
        XCTAssertEqual(
            MaterializedBadge.checkedDirectories(
                filePaths: ["docs/a.txt"], materialized: ["gone/x.txt", "docs/a.txt"]),
            ["docs"]
        )
    }

    /// 深いネストの畳み込み: 中間 dir すべてが独立に判定される。
    func testCheckedDirectoriesNestedRollup() {
        let files = ["a/b/c/d.txt", "a/b/e.txt", "a/f.txt"]
        let checked = MaterializedBadge.checkedDirectories(
            filePaths: files, materialized: ["a/b/c/d.txt", "a/b/e.txt"])
        // a/b/c と a/b は配下全実体化・a は f.txt が dataless なので未チェック
        XCTAssertEqual(checked, ["a/b", "a/b/c"])
    }

    // MARK: - cappedReport

    /// 上限超過はパス昇順 prefix で決定的に切り詰める（`PersistedPathSet.replace` と同一規則）。
    func testCappedReportIsDeterministic() {
        let live: Set<String> = ["c", "a", "b"]
        XCTAssertEqual(MaterializedBadge.cappedReport(live: live, cap: 2), ["a", "b"])
        XCTAssertEqual(MaterializedBadge.cappedReport(live: live, cap: 3), live)
        XCTAssertEqual(MaterializedBadge.cappedReport(live: live, cap: 0), [])
    }

    // MARK: - changedPaths

    /// 点灯（materialize）と消灯（evict）の両方向が files に、チェック反転が directories に出る。
    func testChangedPathsBothDirections() {
        let files = ["docs/a.txt", "docs/b.txt", "top.txt"]
        // materialize: b.txt が増えて docs が全実体化 → docs が反転
        let lit = MaterializedBadge.changedPaths(
            oldFilePaths: files, newFilePaths: files,
            previousReported: ["docs/a.txt"],
            newReport: ["docs/a.txt", "docs/b.txt"]
        )
        XCTAssertEqual(lit.files, ["docs/b.txt"])
        XCTAssertEqual(lit.directories, ["docs"])
        // evict: a.txt が消えて docs のチェックも外れる
        let dimmed = MaterializedBadge.changedPaths(
            oldFilePaths: files, newFilePaths: files,
            previousReported: ["docs/a.txt", "docs/b.txt"],
            newReport: ["docs/b.txt"]
        )
        XCTAssertEqual(dimmed.files, ["docs/a.txt"])
        XCTAssertEqual(dimmed.directories, ["docs"])
    }

    /// ツリーから消えたファイルは files に出ない（削除はマニフェスト diff の delete 側が処理 —
    /// ここで update を出すと削除済み item を蘇生させる）。
    func testChangedPathsIgnoresPathsGoneFromTree() {
        let changed = MaterializedBadge.changedPaths(
            oldFilePaths: ["kept.txt", "deleted.txt"], newFilePaths: ["kept.txt"],
            previousReported: ["kept.txt", "deleted.txt"],
            newReport: ["kept.txt"]
        )
        XCTAssertEqual(changed.files, [])
        XCTAssertEqual(changed.directories, [])
    }

    /// 変化なしなら空（enumerateChanges が badge-only 更新を出さない条件）。
    func testChangedPathsNoop() {
        let files = ["docs/a.txt", "docs/b.txt"]
        let report: Set<String> = ["docs/a.txt"]
        let changed = MaterializedBadge.changedPaths(
            oldFilePaths: files, newFilePaths: files,
            previousReported: report, newReport: report
        )
        XCTAssertEqual(changed.files, [])
        XCTAssertEqual(changed.directories, [])
    }

    // MARK: - ツリー変化起因の dir チェック反転（PR #66 レビュー指摘 1 の回帰）

    /// リモート削除で dataless の子が消え「配下全実体化」になった dir は、実体化集合が
    /// 不変（reported == newReport）でも directories に出る（dirsBefore = 旧ツリー基準）。
    func testChangedPathsDetectsRecheckByRemoteDeletion() {
        let report: Set<String> = ["docs/a.txt"]
        let changed = MaterializedBadge.changedPaths(
            oldFilePaths: ["docs/a.txt", "docs/b.txt"],  // b.txt は dataless だった
            newFilePaths: ["docs/a.txt"],  // リモートが b.txt を削除
            previousReported: report, newReport: report
        )
        XCTAssertEqual(changed.files, [])
        XCTAssertEqual(changed.directories, ["docs"])
    }

    /// チェック済みの dir にリモートが dataless の子を追加（古い mtime = 合成 mtime 不変で
    /// マニフェスト diff に dir が載らないケース）→ チェック消灯が directories に出る。
    /// 固着すると「実体があると誤読される」= 本機能が避けたかった状態の再発（レビュー指摘 1）。
    func testChangedPathsDetectsUncheckByRemoteAddition() {
        let report: Set<String> = ["docs/a.txt"]
        let changed = MaterializedBadge.changedPaths(
            oldFilePaths: ["docs/a.txt"],  // 全実体化でチェック済みだった
            newFilePaths: ["docs/a.txt", "docs/b.txt"],  // リモートが dataless の b.txt を追加
            previousReported: report, newReport: report
        )
        XCTAssertEqual(changed.files, [])
        XCTAssertEqual(changed.directories, ["docs"])
    }

    /// 旧ツリーでのみチェックされていた dir が新ツリーから消えた（配下ファイルゼロ）場合は
    /// directories に出ない（消えた dir はマニフェスト diff の delete 側が処理する）。
    func testChangedPathsFiltersDirectoriesGoneFromNewTree() {
        let changed = MaterializedBadge.changedPaths(
            oldFilePaths: ["gone/a.txt"], newFilePaths: ["other/x.txt"],
            previousReported: ["gone/a.txt"], newReport: []
        )
        XCTAssertEqual(changed.files, [])
        XCTAssertEqual(changed.directories, [])
    }
}
