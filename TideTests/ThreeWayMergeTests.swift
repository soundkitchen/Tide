import XCTest
@testable import Tide

final class ThreeWayMergeTests: XCTestCase {
    private func decide(_ base: String?, _ local: String?, _ remote: String?) -> MergeDecision {
        ThreeWayMerge.decide(base: base, local: local, remote: remote)
    }

    // MARK: - 真理値表（base ∈ {nil,"A"}, local ∈ {nil,"A","B"}, remote ∈ {nil,"A","B","C"}）

    func testTruthTable() {
        // (base, local, remote, expected)
        let cases: [(String?, String?, String?, MergeDecision)] = [
            // remote = nil（削除側）
            (nil, nil, nil, .noop),
            ("A", nil, nil, .noop),
            (nil, "A", nil, .keepLocalRemoteDeleted),   // 未追跡 + リモート削除 → 温存
            ("A", "A", nil, .deleteLocal),              // ベース==ローカル + リモート削除 → 削除
            ("A", "B", nil, .keepLocalRemoteDeleted),   // ローカル編集 + リモート削除 → 温存
            ("B", "A", nil, .keepLocalRemoteDeleted),

            // local = nil（ローカル欠落）→ remote があれば常に download
            (nil, nil, "A", .download),
            ("A", nil, "A", .download),
            ("A", nil, "B", .download),

            // local == remote → 内容一致（fast-forward 含む）
            (nil, "A", "A", .localMatchesRemote),
            ("A", "A", "A", .localMatchesRemote),
            ("B", "A", "A", .localMatchesRemote),       // 両方が同方向に変化（base B → A/A）
            ("A", "B", "B", .localMatchesRemote),

            // local != remote
            ("A", "A", "B", .download),                 // ローカル未編集（base==local）+ リモート変化 → 上書き
            (nil, "A", "B", .conflictThenDownload),     // 未追跡 + 双方別内容 → コンフリクト
            ("A", "B", "C", .conflictThenDownload),     // ローカル編集 + リモートも別 → コンフリクト
            ("A", "B", "A", .conflictThenDownload),     // ローカル編集(B) / リモートはベース(A) のまま → コンフリクト（M2 踏襲）
        ]
        for (base, local, remote, expected) in cases {
            XCTAssertEqual(
                decide(base, local, remote), expected,
                "base=\(base ?? "nil") local=\(local ?? "nil") remote=\(remote ?? "nil")"
            )
        }
    }

    // MARK: - M2 表の各行に対応する named ケース（docs/04-SYNC-LOGIC.md）

    func testRemotePresentLocalMissingDownloads() {
        // 「ローカル無 / リモートあり → ダウンロード」
        XCTAssertEqual(decide("A", nil, "A"), .download)
    }

    func testContentEqualSkipsWithDbRefresh() {
        // 「ローカルあり / SHA = remote → スキップ + DB 最新化」
        XCTAssertEqual(decide("A", "A", "A"), .localMatchesRemote)
        XCTAssertEqual(decide(nil, "X", "X"), .localMatchesRemote)
    }

    func testLocalUntouchedRemoteChangedDownloads() {
        // 「SHA != remote / SHA = DB（前回 sync 時）→ ダウンロード（remote が新しい）」
        XCTAssertEqual(decide("A", "A", "B"), .download)
    }

    func testBothDivergedConflicts() {
        // 「SHA != remote / SHA != DB → コンフリクト（rename → download）」
        XCTAssertEqual(decide("A", "B", "C"), .conflictThenDownload)
        // DB 記録なし（未追跡）でローカルとリモートが別内容も同じくコンフリクト
        XCTAssertEqual(decide(nil, "L", "R"), .conflictThenDownload)
    }

    func testRemoteDeletedUntouchedDeletesLocal() {
        // 「あり / SHA = DB / リモート無 → ローカル削除」
        XCTAssertEqual(decide("A", "A", nil), .deleteLocal)
    }

    func testRemoteDeletedModifiedKeepsLocal() {
        // 「あり / SHA != DB / リモート無 → 温存 + warning」
        XCTAssertEqual(decide("A", "B", nil), .keepLocalRemoteDeleted)
        // 未追跡（DB 記録なし）でリモート削除も温存（誤って消さない）
        XCTAssertEqual(decide(nil, "B", nil), .keepLocalRemoteDeleted)
    }

    func testNothingPresentIsNoop() {
        // 「無 / 無 → 何もしない」
        XCTAssertEqual(decide(nil, nil, nil), .noop)
        XCTAssertEqual(decide("A", nil, nil), .noop)
    }

    // MARK: - fast-forward（両方が同方向に変化）

    func testFastForwardWhenBothMovedToSameContent() {
        // base から両者が同じ内容へ変化 → 取得不要（内容一致）
        XCTAssertEqual(decide("base", "same", "same"), .localMatchesRemote)
    }
}
