import XCTest
import TideCore

/// 列挙のページ / バッチ分割（Issue #131）の符号化と切り出しを固定する。
/// File Provider は 1 回に受け取る件数を推奨サイズの 100 倍までに制限し、超えると拡張を abort する
/// （全件を 1 回で返していた頃は、全再列挙のたびにクラッシュを繰り返して同期が止まった）。
final class FileProviderEnumerationPagingTests: XCTestCase {
    typealias Paging = FileProviderEnumerationPaging

    /// 推奨サイズの 10 倍（上限の 100 倍より十分小さい）。推奨サイズが無ければ既定値の 10 倍。
    func testSizeIsTenTimesTheSuggestion() {
        XCTAssertEqual(Paging.size(suggested: 50), 500)
        XCTAssertEqual(Paging.size(suggested: 200), 2_000)
        XCTAssertEqual(Paging.size(suggested: nil), 2_000)
        XCTAssertEqual(Paging.size(suggested: 0), 2_000)
        XCTAssertEqual(Paging.size(suggested: -1), 2_000)
        XCTAssertLessThan(Paging.sizeMultiplier, 100, "File Provider の上限は推奨サイズの 100 倍")
    }

    // MARK: - enumerateItems のページ

    func testItemPageRoundTripFitsSDKLimit() {
        let page = Paging.ItemPage(anchor: UUID().uuidString, offset: 1_234_567)
        let data = Paging.encode(page)
        XCTAssertEqual(Paging.decodeItemPage(data), page)
        XCTAssertLessThanOrEqual(data.count, 500, "SDK のページ上限は 500 バイト")
    }

    /// システムの初期ページ（ソート指定の定数）や読めないものは nil = 最初のページから。
    func testItemPageRejectsForeignData() {
        XCTAssertNil(Paging.decodeItemPage(Data()))
        XCTAssertNil(Paging.decodeItemPage(Data([0x00, 0xff, 0xfe])))
        XCTAssertNil(Paging.decodeItemPage(Data("tide-items-v1|".utf8)))
        XCTAssertNil(Paging.decodeItemPage(Data("tide-items-v1|anchor|".utf8)))
        XCTAssertNil(Paging.decodeItemPage(Data("tide-items-v1|anchor|-3".utf8)))
        XCTAssertNil(Paging.decodeItemPage(Data("tide-items-v1||3".utf8)))
        XCTAssertNil(Paging.decodeItemPage(Data("tide-items-v1|a|b|3".utf8)))
        XCTAssertNil(Paging.decodeItemPage(Data("tide-changes-v1|a|b|3".utf8)))
    }

    func testSliceWalksAllItemsExactlyOnce() {
        let items = Array(0..<10)
        var collected: [Int] = []
        var offset: Int? = 0
        var pages = 0
        while let current = offset {
            let page = Paging.slice(items, offset: current, size: 3)
            collected += page.items
            offset = page.nextOffset
            pages += 1
        }
        XCTAssertEqual(collected, items)
        XCTAssertEqual(pages, 4)
    }

    func testSliceEdgeCases() {
        XCTAssertTrue(Paging.slice([Int](), offset: 0, size: 3).items.isEmpty)
        XCTAssertNil(Paging.slice([Int](), offset: 0, size: 3).nextOffset)
        // ちょうど割り切れる: 最後のページで nextOffset は nil
        XCTAssertNil(Paging.slice([1, 2, 3], offset: 0, size: 3).nextOffset)
        // 範囲外の offset は空 + nil（固定した世代が同じなら起きない）
        let outside = Paging.slice([1, 2, 3], offset: 5, size: 3)
        XCTAssertTrue(outside.items.isEmpty)
        XCTAssertNil(outside.nextOffset)
        // size 0 以下でも 1 件は進む（無限ループしない）
        XCTAssertEqual(Paging.slice([1, 2, 3], offset: 0, size: 0).items, [1])
    }

    // MARK: - enumerateChanges の途中の anchor

    func testChangeCursorRoundTripFitsSDKLimit() {
        let cursor = Paging.ChangeCursor(
            origin: UUID().uuidString, target: UUID().uuidString, offset: 98_765)
        let data = Paging.encode(cursor)
        XCTAssertEqual(Paging.decodeChangeCursor(String(decoding: data, as: UTF8.self)), cursor)
        XCTAssertLessThanOrEqual(data.count, 500, "SDK の anchor 上限は 500 バイト")
    }

    /// ふつうの世代 anchor（UUID 文字列）は途中の anchor として読まない。
    func testChangeCursorRejectsPlainAnchors() {
        XCTAssertNil(Paging.decodeChangeCursor(UUID().uuidString))
        XCTAssertNil(Paging.decodeChangeCursor("tide-poc-static"))
        XCTAssertNil(Paging.decodeChangeCursor("tide-changes-v1|a|b"))
        XCTAssertNil(Paging.decodeChangeCursor("tide-changes-v1|a||3"))
        XCTAssertNil(Paging.decodeChangeCursor("tide-changes-v1|a|b|x"))
        XCTAssertNil(Paging.decodeChangeCursor("tide-items-v1|a|3"))
    }

    /// 削除 → 更新の順に数えて分け、全件を 1 回ずつ配る。境界は削除と更新をまたげる。
    func testBatchSplitsDeletesThenUpdates() {
        let deleted = (0..<3).map { node("d\($0)") }
        let updated = (0..<4).map { node("u\($0)") }
        let changes = ManifestTreeDiff.Changes(updated: updated, deleted: deleted)

        var gotDeleted: [ManifestTree.Node] = []
        var gotUpdated: [ManifestTree.Node] = []
        var offset: Int? = 0
        var sizes: [Int] = []
        while let current = offset {
            let batch = Paging.batch(changes, offset: current, size: 2)
            gotDeleted += batch.deleted
            gotUpdated += batch.updated
            sizes.append(batch.deleted.count + batch.updated.count)
            offset = batch.nextOffset
        }
        XCTAssertEqual(gotDeleted, deleted)
        XCTAssertEqual(gotUpdated, updated)
        XCTAssertEqual(sizes, [2, 2, 2, 1])
        // 2 回目のバッチは削除 1 件 + 更新 1 件（境界をまたぐ）
        let second = Paging.batch(changes, offset: 2, size: 2)
        XCTAssertEqual(second.deleted.map(\.path), ["d2"])
        XCTAssertEqual(second.updated.map(\.path), ["u0"])
    }

    func testBatchEdgeCases() {
        let empty = ManifestTreeDiff.Changes(updated: [], deleted: [])
        let none = Paging.batch(empty, offset: 0, size: 5)
        XCTAssertTrue(none.deleted.isEmpty && none.updated.isEmpty)
        XCTAssertNil(none.nextOffset)
        // 収まるときは 1 回で全部 + nextOffset nil
        let small = ManifestTreeDiff.Changes(updated: [node("u")], deleted: [node("d")])
        let all = Paging.batch(small, offset: 0, size: 5)
        XCTAssertEqual(all.deleted.count + all.updated.count, 2)
        XCTAssertNil(all.nextOffset)
        // 範囲外の offset は空 + nil
        let outside = Paging.batch(small, offset: 9, size: 5)
        XCTAssertTrue(outside.deleted.isEmpty && outside.updated.isEmpty)
        XCTAssertNil(outside.nextOffset)
    }

    private func node(_ path: String) -> ManifestTree.Node {
        .file(path: path, entry: makeManifestEntry(sha: path))
    }
}
