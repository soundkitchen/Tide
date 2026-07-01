import XCTest
import TideCore
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

    // MARK: - アップロード側（書込シーム）の競合判定 decideUpload

    private func decideUpload(_ base: String?, _ uploading: String, _ remote: String?) -> UploadMergeDecision {
        ThreeWayMerge.decideUpload(base: base, uploading: uploading, remote: remote)
    }

    func testDecideUploadTable() {
        // (base, uploading, remote, expected)
        let cases: [(String?, String, String?, UploadMergeDecision)] = [
            // remote = nil（誰も持っていない / 削除済み）→ 再作成として書込
            (nil, "A", nil, .proceed),
            ("A", "B", nil, .proceed),
            ("A", "A", nil, .proceed),

            // remote == uploading（別書き手が同一内容を確定済み）→ 書込不要
            (nil, "A", "A", .alreadyUpToDate),    // 未追跡でも内容一致なら no-op
            ("A", "B", "B", .alreadyUpToDate),    // 自分の新内容 == 相手の新内容
            ("A", "A", "A", .alreadyUpToDate),    // base==uploading==remote（全一致）

            // remote == base かつ remote != uploading（自分だけ編集・リモート未変化）→ 通常更新
            ("A", "B", "A", .proceed),

            // 双方乖離（相手が base とも自分とも違う内容を上げた）→ コンフリクト
            ("A", "B", "C", .conflict),           // 自分 B / リモート C / base A
            ("A", "C", "B", .conflict),
            (nil, "A", "B", .conflict),           // 未追跡 + リモートに別内容 → コンフリクト
            ("A", "A", "B", .conflict),           // 自分は base のまま再送 / リモートは別内容 → コンフリクト
        ]
        for (base, uploading, remote, expected) in cases {
            XCTAssertEqual(
                decideUpload(base, uploading, remote), expected,
                "base=\(base ?? "nil") uploading=\(uploading) remote=\(remote ?? "nil")"
            )
        }
    }

    func testDecideUploadRemoteAbsentProceeds() {
        // リモート未存在 → 自分の entry で再作成（誰の編集も踏まない）
        XCTAssertEqual(decideUpload("A", "B", nil), .proceed)
        XCTAssertEqual(decideUpload(nil, "X", nil), .proceed)
    }

    func testDecideUploadIdenticalContentIsAlreadyUpToDate() {
        // 別書き手が同一 SHA を確定済み → マニフェスト書込不要
        XCTAssertEqual(decideUpload("base", "same", "same"), .alreadyUpToDate)
        XCTAssertEqual(decideUpload(nil, "same", "same"), .alreadyUpToDate)
    }

    func testDecideUploadRemoteUnchangedProceeds() {
        // リモートが base のまま（自分だけが編集）→ 通常更新
        XCTAssertEqual(decideUpload("A", "B", "A"), .proceed)
    }

    func testDecideUploadDivergedConflicts() {
        // リモートが base とも自分とも別内容 → 無音上書きせずコンフリクト退避
        XCTAssertEqual(decideUpload("A", "B", "C"), .conflict)
        XCTAssertEqual(decideUpload(nil, "L", "R"), .conflict)   // 未追跡 + 別内容
    }
}
