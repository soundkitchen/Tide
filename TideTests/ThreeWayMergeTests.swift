import XCTest
@testable import Tide

final class ThreeWayMergeTests: XCTestCase {
    private func decide(_ base: String?, _ local: LocalState, _ remote: String?) -> MergeDecision {
        ThreeWayMerge.decide(base: base, local: local, remote: remote)
    }

    // MARK: - 分岐網羅（全直積ではなく各分岐の代表ケース）
    // base は nil / "A" / "B" を、local は .absent / .unreadable / .present(...) を使い分ける。

    func testDecisionTable() {
        // (base, local, remote, expected)
        let cases: [(String?, LocalState, String?, MergeDecision)] = [
            // remote = nil（削除側）
            (nil, .absent, nil, .noop),
            ("A", .absent, nil, .noop),
            (nil, .present("A"), nil, .keepLocalRemoteDeleted),   // 未追跡 + リモート削除 → 温存
            ("A", .present("A"), nil, .deleteLocal),              // ベース==ローカル + リモート削除 → 削除
            ("A", .present("B"), nil, .keepLocalRemoteDeleted),   // ローカル編集 + リモート削除 → 温存
            ("B", .present("A"), nil, .keepLocalRemoteDeleted),

            // local = .absent（ローカル欠落）→ remote があれば常に download
            (nil, .absent, "A", .download),
            ("A", .absent, "A", .download),
            ("A", .absent, "B", .download),

            // local == remote → 内容一致（fast-forward 含む）
            (nil, .present("A"), "A", .localMatchesRemote),
            ("A", .present("A"), "A", .localMatchesRemote),
            ("B", .present("A"), "A", .localMatchesRemote),       // 両方が同方向に変化（base B → A/A）
            ("A", .present("B"), "B", .localMatchesRemote),

            // local != remote
            ("A", .present("A"), "B", .download),                 // ローカル未編集（base==local）+ リモート変化 → 上書き
            (nil, .present("A"), "B", .conflictThenDownload),     // 未追跡 + 双方別内容 → コンフリクト
            ("A", .present("B"), "C", .conflictThenDownload),     // ローカル編集 + リモートも別 → コンフリクト
            ("A", .present("B"), "A", .conflictThenDownload),     // ローカル編集(B) / リモートはベース(A) → コンフリクト（M2 踏襲）

            // local = .unreadable（存在するが SHA 計算不能）— base に依らず一意
            (nil, .unreadable, nil, .keepLocalRemoteDeleted),     // 削除側 → 保守的に温存
            ("A", .unreadable, nil, .keepLocalRemoteDeleted),
            (nil, .unreadable, "A", .conflictThenDownload),       // pull 側 → 無確認上書きせずコンフリクト退避
            ("A", .unreadable, "B", .conflictThenDownload),
        ]
        for (base, local, remote, expected) in cases {
            XCTAssertEqual(
                decide(base, local, remote), expected,
                "base=\(base ?? "nil") local=\(local) remote=\(remote ?? "nil")"
            )
        }
    }

    // MARK: - M2 表の各行に対応する named ケース（docs/04-SYNC-LOGIC.md）

    func testRemotePresentLocalMissingDownloads() {
        // 「ローカル無 / リモートあり → ダウンロード」
        XCTAssertEqual(decide("A", .absent, "A"), .download)
    }

    func testContentEqualSkipsWithDbRefresh() {
        // 「ローカルあり / SHA = remote → スキップ + DB 最新化」
        XCTAssertEqual(decide("A", .present("A"), "A"), .localMatchesRemote)
        XCTAssertEqual(decide(nil, .present("X"), "X"), .localMatchesRemote)
    }

    func testLocalUntouchedRemoteChangedDownloads() {
        // 「SHA != remote / SHA = DB（前回 sync 時）→ ダウンロード（remote が新しい）」
        XCTAssertEqual(decide("A", .present("A"), "B"), .download)
    }

    func testBothDivergedConflicts() {
        // 「SHA != remote / SHA != DB → コンフリクト（rename → download）」
        XCTAssertEqual(decide("A", .present("B"), "C"), .conflictThenDownload)
        // DB 記録なし（未追跡）でローカルとリモートが別内容も同じくコンフリクト
        XCTAssertEqual(decide(nil, .present("L"), "R"), .conflictThenDownload)
    }

    func testRemoteDeletedUntouchedDeletesLocal() {
        // 「あり / SHA = DB / リモート無 → ローカル削除」
        XCTAssertEqual(decide("A", .present("A"), nil), .deleteLocal)
    }

    func testRemoteDeletedModifiedKeepsLocal() {
        // 「あり / SHA != DB / リモート無 → 温存 + warning」
        XCTAssertEqual(decide("A", .present("B"), nil), .keepLocalRemoteDeleted)
        // 未追跡（DB 記録なし）でリモート削除も温存（誤って消さない）
        XCTAssertEqual(decide(nil, .present("B"), nil), .keepLocalRemoteDeleted)
    }

    func testNothingPresentIsNoop() {
        // 「無 / 無 → 何もしない」
        XCTAssertEqual(decide(nil, .absent, nil), .noop)
        XCTAssertEqual(decide("A", .absent, nil), .noop)
    }

    // MARK: - fast-forward（両方が同方向に変化）

    func testFastForwardWhenBothMovedToSameContent() {
        // base から両者が同じ内容へ変化 → 取得不要（内容一致）
        XCTAssertEqual(decide("base", .present("same"), "same"), .localMatchesRemote)
    }

    // MARK: - unreadable（存在するが SHA 計算不能）の非対称を decide() に集約（PR #3 指摘 1）

    func testUnreadableOnPullConservativelyConflicts() {
        // pull 側（remote あり）: 乖離の有無を確認できない → 無確認上書きせずコンフリクト退避
        XCTAssertEqual(decide(nil, .unreadable, "R"), .conflictThenDownload)
        XCTAssertEqual(decide("A", .unreadable, "R"), .conflictThenDownload)
    }

    func testUnreadableOnDeletionKeepsLocal() {
        // 削除側（remote なし）: 未編集と確認できない → 保守的に温存
        XCTAssertEqual(decide(nil, .unreadable, nil), .keepLocalRemoteDeleted)
        XCTAssertEqual(decide("A", .unreadable, nil), .keepLocalRemoteDeleted)
    }
}
