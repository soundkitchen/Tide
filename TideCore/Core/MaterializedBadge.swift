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
    /// - files: reported と newReport の対称差のうち**現ツリーに実在するファイルのみ**
    ///   （消えたファイルはマニフェスト diff の delete 側が処理する = ここで update を出すと
    ///   削除済み item を蘇生させてしまう）。
    /// - directories: チェック集合（`checkedDirectories`）の反転分（点灯 ⇄ 消灯の両方向）。
    public static func changedPaths(
        filePaths: [String], previousReported: Set<String>, newReport: Set<String>
    ) -> (files: Set<String>, directories: Set<String>) {
        let files = Set(filePaths).intersection(previousReported.symmetricDifference(newReport))
        let dirsBefore = checkedDirectories(filePaths: filePaths, materialized: previousReported)
        let dirsAfter = checkedDirectories(filePaths: filePaths, materialized: newReport)
        return (files, dirsBefore.symmetricDifference(dirsAfter))
    }
}
