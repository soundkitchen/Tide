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
        ChangeContext(
            oldFilePaths: oldFilePaths, newFilePaths: newFilePaths, previousReported: previousReported
        ).changedPaths(newReport: newReport)
    }

    /// バッジ差分の計算の文脈。報告集合を変えて何度も計算するとき（`partialReport`）に、
    /// 変わらない部分（新ツリーのファイル集合・dirsBefore・配下にファイルがある dir）を 1 回だけ
    /// 計算する（Issue #131・PR #132 レビュー N3）。
    public struct ChangeContext: Sendable {
        private let newFilePaths: [String]
        private let newFileSet: Set<String>
        private let previousReported: Set<String>
        private let dirsBefore: Set<String>
        private let currentDirs: Set<String>

        /// - Parameter deliveredDirectories: 同じ差分の途中のバッチ（Issue #131）で、すでに
        ///   「新ツリー × previousReported」のフラグで配った dir。Finder はこの状態を見ているので、
        ///   これらの dir の「前」は旧ツリーではなく新ツリー基準で数える（PR #132 レビュー B1:
        ///   旧ツリー基準のままだと、途中で配った状態と最後の報告集合の状態が食い違っても反転と
        ///   判定されず、配り直されずに固着する）。
        public init(
            oldFilePaths: [String], newFilePaths: [String], previousReported: Set<String>,
            deliveredDirectories: Set<String> = []
        ) {
            self.newFilePaths = newFilePaths
            self.newFileSet = Set(newFilePaths)
            self.previousReported = previousReported
            let beforeOld = MaterializedBadge.checkedDirectories(
                filePaths: oldFilePaths, materialized: previousReported)
            if deliveredDirectories.isEmpty {
                self.dirsBefore = beforeOld
            } else {
                let beforeNew = MaterializedBadge.checkedDirectories(
                    filePaths: newFilePaths, materialized: previousReported)
                self.dirsBefore = beforeOld.subtracting(deliveredDirectories)
                    .union(beforeNew.intersection(deliveredDirectories))
            }
            self.currentDirs = MaterializedBadge.directoriesContainingFiles(newFilePaths)
        }

        /// 報告集合を `newReport` に進めたときに didUpdate へ載せるべきパス（意味は `changedPaths`）。
        public func changedPaths(newReport: Set<String>) -> (files: Set<String>, directories: Set<String>) {
            let files = newFileSet.intersection(previousReported.symmetricDifference(newReport))
            let dirsAfter = MaterializedBadge.checkedDirectories(
                filePaths: newFilePaths, materialized: newReport)
            return (files, dirsBefore.symmetricDifference(dirsAfter).intersection(currentDirs))
        }

        /// バッジ差分を 1 回で配りきれないときの「途中まで進めた報告集合」（Issue #131）と、
        /// そのとき配るパス。`changedPaths`（files + directories）の件数が `budget` 以内に収まるよう、
        /// previousReported から newReport へ向けて**先頭 k 件の切り替えだけ**進める。全体が budget
        /// 以内なら newReport そのもの。
        /// - 切り替えは「外す方（パス昇順）→ 足す方（パス昇順）」の順に進める（PR #132 レビュー B2）:
        ///   途中の集合が previousReported と newReport の大きい方を超えない = レジストリ上限
        ///   （`materializedBadgeCap`）を超えない。超えると `replace(with:)` の切り詰めで、Finder に
        ///   報告した集合と永続化した集合が食い違い、外す通知を配っていないパスのバッジが固着する。
        /// - k は budget から半分ずつ減らして探す（1 ファイルで dir の反転が祖先ぶん増えうるため）。
        ///   k = 1 でも超える場合はそのまま返す（上限は推奨サイズの 100 倍なので、祖先 dir ぶんの
        ///   はみ出しは問題にならない）。少なくとも 1 件は必ず進む = 繰り返せば newReport に収束する
        ///   （残りは呼び出し側が自己 signal で次の enumerateChanges に回す）。
        /// - 報告集合は同じでツリーだけが変わった反転（dir のみ）は、進める単位が無いので丸ごと返す。
        public func partialReport(
            newReport: Set<String>, budget: Int
        ) -> (report: Set<String>, files: Set<String>, directories: Set<String>) {
            let full = changedPaths(newReport: newReport)
            if full.files.count + full.directories.count <= budget {
                return (newReport, full.files, full.directories)
            }
            let removals = previousReported.subtracting(newReport).sorted()
            let additions = newReport.subtracting(previousReported).sorted()
            let toggles = removals + additions
            guard !toggles.isEmpty else { return (newReport, full.files, full.directories) }
            var k = max(1, min(budget, toggles.count))
            while true {
                var partial = previousReported
                for path in toggles.prefix(k) {
                    if newReport.contains(path) {
                        partial.insert(path)
                    } else {
                        partial.remove(path)
                    }
                }
                let changed = changedPaths(newReport: partial)
                if k == 1 || changed.files.count + changed.directories.count <= budget {
                    return (partial, changed.files, changed.directories)
                }
                k /= 2
            }
        }
    }

    /// filePaths の祖先 dir 全集合（= 配下に 1 ファイル以上ある dir。ルート `""` は含まない）。
    fileprivate static func directoriesContainingFiles(
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
