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

    // MARK: - partialReport（Issue #131: バッジ差分をバッチの大きさに収める）

    private func context(
        _ old: [String], _ new: [String], _ previous: Set<String>, delivered: Set<String> = []
    ) -> MaterializedBadge.ChangeContext {
        MaterializedBadge.ChangeContext(
            oldFilePaths: old, newFilePaths: new, previousReported: previous, deliveredDirectories: delivered)
    }

    /// 全体が枠に収まるなら newReport そのもの。
    func testPartialReportReturnsFullReportWithinBudget() {
        let files = ["a/1", "a/2", "b/1"]
        let partial = context(files, files, []).partialReport(newReport: ["b/1"], budget: 10)
        XCTAssertEqual(partial.report, ["b/1"])
        XCTAssertEqual(partial.files, ["b/1"])
        XCTAssertEqual(partial.directories, ["b"])
    }

    /// 枠を超えるなら一部だけ進め、配る件数（files + dirs）を枠に収める。繰り返せば newReport に収束する。
    /// 返すパスは、その途中の集合へ進めたときの `changedPaths` と一致する。
    func testPartialReportConvergesWithinBudget() {
        let files = (0..<20).map { "dir\($0 % 4)/f\($0)" }
        let target = Set(files)
        var reported: Set<String> = []
        var rounds = 0
        while reported != target {
            let ctx = context(files, files, reported)
            let next = ctx.partialReport(newReport: target, budget: 5)
            XCTAssertLessThanOrEqual(next.files.count + next.directories.count, 5)
            let expected = ctx.changedPaths(newReport: next.report)
            XCTAssertEqual(next.files, expected.files)
            XCTAssertEqual(next.directories, expected.directories)
            XCTAssertNotEqual(next.report, reported, "1 回で少なくとも 1 ファイルは進む")
            reported = next.report
            rounds += 1
            XCTAssertLessThan(rounds, 100)
        }
    }

    /// 消灯方向（報告済みから外す）も同じく進む。
    func testPartialReportAlsoShrinks() {
        let files = (0..<10).map { "d/f\($0)" }
        let partial = context(files, files, Set(files)).partialReport(newReport: [], budget: 3)
        XCTAssertLessThan(partial.report.count, files.count)
        XCTAssertTrue(partial.report.isSubset(of: Set(files)))
    }

    /// PR #132 レビュー B2: 外す方を先に進めるので、途中の集合が previous と newReport の大きい方
    /// （= レジストリ上限以内）を超えない。追加がパス順で前・削除が後ろにある並びでも同じ。
    func testPartialReportNeverExceedsTheLargerOfBothReports() {
        let files = ["a/1", "a/2", "a/3", "z/1", "z/2", "z/3"]
        let previous: Set<String> = ["z/1", "z/2", "z/3"]
        let full: Set<String> = ["a/1", "a/2", "a/3"]
        var reported = previous
        var rounds = 0
        while reported != full {
            let next = context(files, files, reported).partialReport(newReport: full, budget: 2)
            XCTAssertLessThanOrEqual(next.report.count, max(previous.count, full.count))
            reported = next.report
            rounds += 1
            XCTAssertLessThan(rounds, 100)
        }
    }

    /// 報告集合は同じでツリーだけが変わった反転（dir のみ）は、進める単位が無いので丸ごと返す
    /// （無限ループしない）。
    func testPartialReportWithOnlyTreeChangeReturnsNewReport() {
        let partial = context(["a/1", "a/2"], ["a/1"], ["a/1"]).partialReport(newReport: ["a/1"], budget: 0)
        XCTAssertEqual(partial.report, ["a/1"])
        XCTAssertEqual(partial.directories, ["a"], "a/2 の削除で a は全実体化 = チェックが付く")
    }

    /// PR #132 レビュー B1: 同じ差分の途中のバッチで「新ツリー × previous」のフラグで配った dir は、
    /// その状態を「前」として数える。旧ツリー基準のままだと、最後の報告集合で状態が戻ったとき
    /// 反転と判定されず、途中で配ったチェックが固着する。
    func testDeliveredDirectoriesUseTheStateFinderSaw() {
        let old = ["D/a", "D/b"]   // 起点: a 実体化・b 未実体化 → D は未チェック
        let new = ["D/a"]          // b がリモートで削除 → 途中のバッチで D はチェック付きで配られた
        let previous: Set<String> = ["D/a"]
        let newReport: Set<String> = []  // 最後のバッチまでに a が evict された
        // 旧ツリー基準: 前 = 未チェック / 後 = 未チェック → 反転なし（固着の原因）
        XCTAssertEqual(context(old, new, previous).changedPaths(newReport: newReport).directories, [])
        // 途中で配った dir は新ツリー基準: 前 = チェック付き / 後 = 未チェック → 配り直す
        XCTAssertEqual(
            context(old, new, previous, delivered: ["D"]).changedPaths(newReport: newReport).directories,
            ["D"])
    }
}
