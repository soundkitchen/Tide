import Foundation

/// FP 拡張の列挙をページ / バッチに分けるための純粋計算（Issue #131）。
///
/// File Provider は 1 回に受け取る件数を「推奨サイズ（`suggestedPageSize` /
/// `suggestedBatchSize`）の 100 倍まで」に制限し、超えると `__FILEPROVIDER_OBSERVER_TOO_MANY_ITEMS__`
/// の assert で拡張を abort する。working set を全件 1 回で返していた頃は、ノードが上限を超えると
/// anchor の失効（全再列挙）のたびにクラッシュを繰り返し、同期が止まった。
///
/// - `enumerateItems`: 最初のページの世代に固定してページを分ける（2026-10-17 ユーザ確定）。
///   ページには「固定した世代の anchor + 何件目まで返したか」を入れる。返した中身と
///   `currentSyncAnchor` が必ず一致する（提示内容と anchor のずれで diff が漏れる窓を作らない）。
/// - 1 回に返す件数は推奨サイズの 10 倍（`size(suggested:)`）。
/// - `enumerateChanges`: 差分がバッチの大きさを超えたら、途中までを返して `moreComing` にし、
///   続きの位置を anchor（「起点世代 → 目標世代 + 何件目まで返したか」）に入れる。
///
/// どちらの符号化も SDK の上限（500 バイト）に収まる（世代 anchor は UUID 文字列）。
public enum FileProviderEnumerationPaging {
    /// システムが推奨サイズを示さないときの推奨サイズの代わり。
    public static let defaultSuggestedSize = 200
    /// 推奨サイズの何倍を 1 回に返すか（2026-10-17 ユーザ確定）。上限は 100 倍なので十分な余裕がある。
    /// 推奨サイズ（working set では 200）のままだと 3 万件の全再列挙が 151 ページになり、
    /// 大量の書込で世代が進む中では列挙を終える前に固定した世代が落ちた（Issue #131 の実測）。
    public static let sizeMultiplier = 10

    /// 1 回に返す件数 = 推奨サイズ × `sizeMultiplier`（推奨サイズが無い・0 以下は既定値を使う）。
    public static func size(suggested: Int?) -> Int {
        guard let suggested, suggested > 0 else { return defaultSuggestedSize * sizeMultiplier }
        return suggested * sizeMultiplier
    }

    // MARK: - enumerateItems のページ

    /// `enumerateItems` の続きのページ。
    public struct ItemPage: Equatable, Sendable {
        /// 固定した世代の anchor。
        public let anchor: String
        /// ここまでに返した件数（次に返す先頭の位置）。
        public let offset: Int

        public init(anchor: String, offset: Int) {
            self.anchor = anchor
            self.offset = offset
        }
    }

    private static let itemPagePrefix = "tide-items-v1|"

    public static func encode(_ page: ItemPage) -> Data {
        Data("\(itemPagePrefix)\(page.anchor)|\(page.offset)".utf8)
    }

    /// 自分が作ったページなら復号する。システムの初期ページ（`NSFileProviderInitialPageSortedByName`
    /// など）や読めないものは nil = 最初のページから始める。
    public static func decodeItemPage(_ data: Data) -> ItemPage? {
        guard let string = String(data: data, encoding: .utf8),
              string.hasPrefix(itemPagePrefix) else { return nil }
        let fields = string.dropFirst(itemPagePrefix.count).split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count == 2, !fields[0].isEmpty,
              let offset = Int(fields[1]), offset >= 0 else { return nil }
        return ItemPage(anchor: String(fields[0]), offset: offset)
    }

    /// `items[offset...]` から `size` 件を切り出す。`nextOffset` は続きがあればその位置、
    /// 最後まで返したら nil。範囲外の offset（固定した世代が同じなら起きない）は空 + nil。
    public static func slice<T>(_ items: [T], offset: Int, size: Int) -> (items: [T], nextOffset: Int?) {
        guard offset >= 0, offset < items.count else { return ([], nil) }
        let end = min(offset + max(size, 1), items.count)
        return (Array(items[offset..<end]), end < items.count ? end : nil)
    }

    // MARK: - enumerateChanges の anchor

    /// `enumerateChanges` の途中の anchor（差分を分けて返している最中）。
    public struct ChangeCursor: Equatable, Sendable {
        /// 差分の起点の世代 anchor（システムが最後に見た世代）。
        public let origin: String
        /// 差分の目標の世代 anchor（分割を始めた時点の最新世代）。
        public let target: String
        /// ここまでに返した変化の件数（削除 → 更新の順に数える）。
        public let offset: Int

        public init(origin: String, target: String, offset: Int) {
            self.origin = origin
            self.target = target
            self.offset = offset
        }
    }

    private static let changeCursorPrefix = "tide-changes-v1|"

    public static func encode(_ cursor: ChangeCursor) -> Data {
        Data("\(changeCursorPrefix)\(cursor.origin)|\(cursor.target)|\(cursor.offset)".utf8)
    }

    /// 途中の anchor なら復号する。ふつうの世代 anchor は nil。
    public static func decodeChangeCursor(_ string: String) -> ChangeCursor? {
        guard string.hasPrefix(changeCursorPrefix) else { return nil }
        let fields = string.dropFirst(changeCursorPrefix.count).split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count == 3, !fields[0].isEmpty, !fields[1].isEmpty,
              let offset = Int(fields[2]), offset >= 0 else { return nil }
        return ChangeCursor(origin: String(fields[0]), target: String(fields[1]), offset: offset)
    }

    /// 差分のうち、`offset` 件目から `size` 件を返す（削除 → 更新の順に数える）。
    /// `nextOffset` は続きがあればその位置、最後まで返したら nil。
    /// 1 つの id は削除か更新のどちらか一方にしか現れない（種別変化は旧 kind の削除と新 kind の
    /// 更新 = 別 id・`ManifestTreeDiff`）ので、境界をまたいでも同じ id の削除と更新が
    /// 別の回に分かれることはない。
    public static func batch(
        _ changes: ManifestTreeDiff.Changes, offset: Int, size: Int
    ) -> (deleted: [ManifestTree.Node], updated: [ManifestTree.Node], nextOffset: Int?) {
        let total = changes.deleted.count + changes.updated.count
        guard offset >= 0, offset < total else { return ([], [], nil) }
        let end = min(offset + max(size, 1), total)
        let deletedCount = changes.deleted.count
        let deleted = offset < deletedCount
            ? Array(changes.deleted[offset..<min(end, deletedCount)]) : []
        let updatedStart = max(offset - deletedCount, 0)
        let updatedEnd = max(end - deletedCount, 0)
        let updated = updatedStart < updatedEnd ? Array(changes.updated[updatedStart..<updatedEnd]) : []
        return (deleted, updated, end < total ? end : nil)
    }
}
