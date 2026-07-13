import Foundation

/// 実体化バッジ（Issue #65）の純粋判定。FP の型には依存しない — `TideFileProvider` ターゲットは
/// TideTests から import できないため、テスト可能なロジックは TideCore に置く（`FileProviderWritePolicy`
/// と同じ方針）。
///
/// 用語:
/// - **live**: fileproviderd が報告する「いま実体化されている」ファイルパス集合（OS が真実を持つ。
///   `NSFileProviderManager.enumeratorForMaterializedItems()` で取得）。
/// - **reported**: 拡張が Finder へ最後に報告した集合（`PersistedPathSet` に永続化）。バッジの
///   点灯/消灯は「live と reported の差分」を working set の enumerateChanges の didUpdate に
///   合流させて届ける。anchor（マニフェスト世代）意味論とは独立の eventual なオーバーレイ
///   （docs/09 の設計判断）。
public enum MaterializedBadge {
    /// チェックを付けるディレクトリ集合: **配下に 1 ファイル以上あり、かつ配下全ファイルが
    /// 実体化済み**（2026-07-14 ユーザ確定）。空フォルダ・仮想フォルダは対象外（`filePaths` に
    /// 配下ファイルが無い dir はそもそも集計に現れない）。ルート（`""`）は対象外。
    public static func checkedDirectories(
        filePaths: some Sequence<String>, materialized: Set<String>
    ) -> Set<String> {
        var total: [String: Int] = [:]
        var done: [String: Int] = [:]
        for path in filePaths {
            let isMaterialized = materialized.contains(path)
            var ancestor = ""
            for component in path.split(separator: "/").dropLast() {
                ancestor = ancestor.isEmpty ? String(component) : "\(ancestor)/\(component)"
                total[ancestor, default: 0] += 1
                if isMaterialized { done[ancestor, default: 0] += 1 }
            }
        }
        return Set(total.compactMap { dir, count in done[dir] == count ? dir : nil })
    }

    /// live 集合をレジストリ上限に合わせて**パス昇順の prefix で決定的に**切り詰める。
    /// `PersistedPathSet.replace(with:)` の切り詰め規則と同一 — 報告した集合と永続化した集合が
    /// 食い違うと、溢れた分が毎回 didUpdate に再送されるチャーンになる（溢れた分はバッジが
    /// 付かないだけ = 安全側）。
    public static func cappedReport(live: Set<String>, cap: Int) -> Set<String> {
        guard live.count > cap else { return live }
        return Set(live.sorted().prefix(max(cap, 0)))
    }

    /// バッジ変化として didUpdate に載せるべきパス。
    /// - files: reported と newReport の対称差のうち**新ツリーに実在するファイルのみ**
    ///   （消えたファイルはマニフェスト diff の delete 側が処理する = ここで update を出すと
    ///   削除済み item を蘇生させてしまう）。
    /// - directories: チェック集合（`checkedDirectories`）の反転分（点灯 ⇄ 消灯の両方向）。
    ///   **dirsBefore は旧ツリー（= Finder が最後に見た世代）基準**（PR #66 レビュー指摘 1）:
    ///   両側を新ツリーで計算すると「実体化集合は不変・ツリーだけが変わった」反転（リモート
    ///   削除で全実体化化 / リモートの古い mtime ファイル追加で dataless 混入 — どちらも dir の
    ///   合成 mtime が動かずマニフェスト diff に dir が載らないケース）が対称差に現れず、
    ///   チェックが固着する。新ツリーに配下ファイルを持たない dir は配信対象外
    ///   （消えた dir はマニフェスト diff の delete 側が処理する）。
    public static func changedPaths(
        oldFilePaths: [String], newFilePaths: [String],
        previousReported: Set<String>, newReport: Set<String>
    ) -> (files: Set<String>, directories: Set<String>) {
        let files = Set(newFilePaths).intersection(previousReported.symmetricDifference(newReport))
        let dirsBefore = checkedDirectories(filePaths: oldFilePaths, materialized: previousReported)
        let dirsAfter = checkedDirectories(filePaths: newFilePaths, materialized: newReport)
        let currentDirs = directoriesContainingFiles(newFilePaths)
        return (
            files,
            dirsBefore.symmetricDifference(dirsAfter).intersection(currentDirs)
        )
    }

    /// filePaths の祖先 dir 全集合（= 配下に 1 ファイル以上ある dir。ルート `""` は含まない）。
    private static func directoriesContainingFiles(
        _ filePaths: some Sequence<String>
    ) -> Set<String> {
        var dirs: Set<String> = []
        for path in filePaths {
            var ancestor = ""
            for component in path.split(separator: "/").dropLast() {
                ancestor = ancestor.isEmpty ? String(component) : "\(ancestor)/\(component)"
                dirs.insert(ancestor)
            }
        }
        return dirs
    }
}
