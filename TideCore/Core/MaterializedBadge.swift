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

    /// 書込・実体化コールバック（createItem / modifyItem / fetchContents）の返却 item に実体化
    /// フラグを付けてよいか（Issue #138）。`reported` に `path` を足して `cappedReport` で切り詰めた
    /// ときに `path` が残るか、と同じ規則。上限の外のパスに付けると、直後の差分配信が
    /// `cappedReport` で外したフラグで同じ item を再送し、版が変わる（= バッジのちらつき）。
    /// その再送がローカルの除外名への改名と重なると、fileproviderd が旧名をディスクへ戻そうと
    /// して失敗し続け、後片付けの削除が来なくなる。
    public static func fitsReport(path: String, reported: Set<String>, cap: Int) -> Bool {
        guard cap > 0 else { return false }
        if reported.count < cap || reported.contains(path) { return true }
        guard let last = reported.max() else { return true }
        return path < last
    }

    /// 除外名への改名で後片付けを予約した path（`frozen`）のバッジを、Finder へ伝え済みの状態
    /// （`told`）のまま据え置いた報告集合（Issue #138）。予約から後片付けの削除までの間に旧 item の
    /// 版を変えて再通知すると、fileproviderd が旧名をディスクへ戻そうとして失敗し続け、後片付けが
    /// 来なくなる。凍結した path は報告の差分に現れないので配信もされない。
    public static func pinning(
        _ target: Set<String>, to told: Set<String>, frozen: Set<String>
    ) -> Set<String> {
        guard !frozen.isEmpty else { return target }
        return target.subtracting(frozen).union(told.intersection(frozen))
    }

    /// `path` が `root` 自身かその配下か。
    fileprivate static func isInSubtree(_ path: String, of root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    /// `path` を `from` → `to` の subtree 移動に追従させる（`from` の外なら nil）。
    fileprivate static func renamed(_ path: String, from: String, to: String) -> String? {
        if path == from { return to }
        let prefix = from + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return to + "/" + path.dropFirst(prefix.count)
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
        previousReported: Set<String>, newReport: Set<String>,
        pendingReturned: Set<String> = []
    ) -> (files: Set<String>, directories: Set<String>) {
        ChangeContext(
            oldFilePaths: oldFilePaths, newFilePaths: newFilePaths, previousReported: previousReported,
            pendingReturned: pendingReturned
        ).changedPaths(newReport: newReport)
    }

    /// バッジ差分の計算の文脈。報告集合を変えて何度も計算するとき（`partialReport`）に、
    /// 変わらない部分（新ツリーのファイル集合・dirsBefore・配下にファイルがある dir）を 1 回だけ
    /// 計算する（Issue #131・PR #132 レビュー N3）。
    public struct ChangeContext: Sendable {
        private let newFilePaths: [String]
        private let newFileSet: Set<String>
        /// Finder へ伝え済みのファイル（previousReported + pendingReturned）。ファイルの差分と
        /// `partialReport` の起点はこちら。
        private let told: Set<String>
        private let dirsBefore: Set<String>
        private let currentDirs: Set<String>

        /// - Parameter deliveredDirectories: 同じ差分の途中のバッチ（Issue #131）で、すでに
        ///   「新ツリー × previousReported」のフラグで配った dir。Finder はこの状態を見ているので、
        ///   これらの dir の「前」は旧ツリーではなく新ツリー基準で数える（PR #132 レビュー B1:
        ///   旧ツリー基準のままだと、途中で配った状態と最後の報告集合の状態が食い違っても反転と
        ///   判定されず、配り直されずに固着する）。
        /// - Parameter pendingReturned: 書込・実体化コールバックの返却 item で「実体化済み」と
        ///   伝えたが、まだ previousReported に畳み込んでいないファイル（Issue #138）。ファイルは
        ///   伝え済みとして数える（再送しない）。dir は返却 item で伝えていないので、dirsBefore は
        ///   previousReported だけで数える。
        public init(
            oldFilePaths: [String], newFilePaths: [String], previousReported: Set<String>,
            deliveredDirectories: Set<String> = [], pendingReturned: Set<String> = []
        ) {
            self.newFilePaths = newFilePaths
            self.newFileSet = Set(newFilePaths)
            self.told = previousReported.union(pendingReturned)
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
            let files = newFileSet.intersection(told.symmetricDifference(newReport))
            let dirsAfter = MaterializedBadge.checkedDirectories(
                filePaths: newFilePaths, materialized: newReport)
            return (files, dirsBefore.symmetricDifference(dirsAfter).intersection(currentDirs))
        }

        /// バッジ差分を 1 回で配りきれないときの「途中まで進めた報告集合」（Issue #131）と、
        /// そのとき配るパス。`changedPaths`（files + directories）の件数が `budget` 以内に収まるよう、
        /// 伝え済みの集合（previousReported + pendingReturned）から newReport へ向けて**先頭 k 件の
        /// 切り替えだけ**進める。全体が budget 以内なら newReport そのもの。
        /// - 切り替えは「外す方（パス昇順）→ 足す方（パス昇順）」の順に進める（PR #132 レビュー B2）:
        ///   途中の集合が伝え済みの集合と newReport の大きい方を超えない = レジストリ上限
        ///   （`materializedBadgeCap`）を超えない（伝え済みの集合は返却分で上限を超えうるが、
        ///   超えた分は外す方の切り替えに含まれ、先に進む）。超えると `replace(with:)` の切り詰めで、Finder に
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
            let removals = told.subtracting(newReport).sorted()
            let additions = newReport.subtracting(told).sorted()
            let toggles = removals + additions
            guard !toggles.isEmpty else { return (newReport, full.files, full.directories) }
            var k = max(1, min(budget, toggles.count))
            while true {
                var partial = told
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

    /// 返却 item で「実体化済み」と伝えたファイルの台帳（Issue #138）。
    ///
    /// createItem / modifyItem / fetchContents は内容がローカルにあるので、返却 item に実体化
    /// フラグを付ける。ところが fileproviderd の実体化セット（live）の観測はその後になるため、
    /// 観測が来るまでの差分配信は同じ item をフラグなしで再送し、版が変わる（バッジのちらつき）。
    /// 台帳は返したパスを 2 つの役目で持つ:
    /// - **未確認**（返したあとに始まった観測がまだ反映されていない）: live に足して扱う。
    /// - **未畳み込み**（報告済み集合 reported にまだ入っていない）: Finder へ伝え済みとして扱う
    ///   （`ChangeContext` の pendingReturned）。
    /// 確認済みのエントリは、報告点（working set の enumerateChanges）が reported を前進させたときに
    /// 畳み込んで外す。観測で確認しただけで外すと、返した直後に退避されたファイルの消灯を
    /// 配らないまま reported と食い違い、バッジが残る。
    public struct ReturnLedger: Sendable, Equatable {
        /// path → 返したときまでに始まっていた観測の数
        private var entries: [String: UInt64] = [:]
        private var queriesStarted: UInt64 = 0
        private var lastApplied: UInt64 = 0

        public init() {}

        /// 返却 item に実体化フラグを付けて返した。
        public mutating func noteReturned(_ path: String) {
            entries[path] = queriesStarted
        }

        /// 実体化セットの観測を始める。返値は `shouldApply` に渡す番号。
        public mutating func beginQuery() -> UInt64 {
            queriesStarted += 1
            return queriesStarted
        }

        /// 観測の結果を live に反映してよいか（後から始まった観測が先に反映されていたら false）。
        /// true のとき、この観測より前に返したエントリは確認済みになる。
        public mutating func shouldApply(query: UInt64) -> Bool {
            guard query > lastApplied else { return false }
            lastApplied = query
            return true
        }

        /// 未畳み込みの全パス（Finder へ伝え済みとして扱う）。
        public var pending: Set<String> { Set(entries.keys) }

        /// 未確認のパス（live に足して扱う）。
        public var unconfirmed: Set<String> {
            Set(entries.compactMap { $0.value >= lastApplied ? $0.key : nil })
        }

        /// 報告点で畳み込むときの印。`fold(_:)` に渡す。
        public var confirmedMarks: [String: UInt64] {
            entries.filter { $0.value < lastApplied }
        }

        /// `confirmedMarks` を取ったあと reported を前進させたので、その確認済みエントリを外す。
        /// 取ったあとに同じパスを返し直していたら（印が変わっていたら）残す。
        public mutating func fold(_ marks: [String: UInt64]) {
            for (path, mark) in marks where entries[path] == mark {
                entries[path] = nil
            }
        }

        /// subtree の移動に追従する（reported の `renameSubtree` と揃える）。
        public mutating func renameSubtree(from: String, to: String) {
            var next: [String: UInt64] = [:]
            for (path, mark) in entries {
                next[MaterializedBadge.renamed(path, from: from, to: to) ?? path] = mark
            }
            entries = next
        }

        /// subtree の削除に追従する（reported の `removeSubtree` と揃える）。
        public mutating func removeSubtree(at root: String) {
            entries = entries.filter { !MaterializedBadge.isInSubtree($0.key, of: root) }
        }
    }

    /// live 集合を subtree の移動に追従させる（`ReturnLedger.renameSubtree` と同じ規則）。
    public static func renamingSubtree(
        _ paths: Set<String>, from: String, to: String
    ) -> Set<String> {
        Set(paths.map { renamed($0, from: from, to: to) ?? $0 })
    }

    /// live 集合から subtree を除く（`ReturnLedger.removeSubtree` と同じ規則）。
    public static func removingSubtree(_ paths: Set<String>, at root: String) -> Set<String> {
        paths.filter { !isInSubtree($0, of: root) }
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
