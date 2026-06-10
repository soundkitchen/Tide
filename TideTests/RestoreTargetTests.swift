import XCTest
@testable import Tide

/// 復元先決定（ハイブリッド）の純粋ロジック全分岐。
final class RestoreTargetTests: XCTestCase {
    func testDecisionTable() {
        // ローカル不在 → 上書き対象が無いので原パスへ。
        XCTAssertEqual(
            RestoreTarget.decide(localExists: false, localSha: nil, dbRecordSha: nil), .writeOriginal)
        XCTAssertEqual(
            RestoreTarget.decide(localExists: false, localSha: nil, dbRecordSha: "A"), .writeOriginal)

        // 存在するが読めない（symlink / I/O）→ 退避。
        XCTAssertEqual(
            RestoreTarget.decide(localExists: true, localSha: nil, dbRecordSha: "A"), .divertToCopy)
        XCTAssertEqual(
            RestoreTarget.decide(localExists: true, localSha: nil, dbRecordSha: nil), .divertToCopy)

        // 現在の内容 == 最後に同期した内容 → 未同期編集なし。上書き可。
        XCTAssertEqual(
            RestoreTarget.decide(localExists: true, localSha: "A", dbRecordSha: "A"), .writeOriginal)

        // 未同期の編集（現在 != DB 記録）→ 退避。
        XCTAssertEqual(
            RestoreTarget.decide(localExists: true, localSha: "B", dbRecordSha: "A"), .divertToCopy)

        // 未追跡（DB 記録なし）→ 退避。
        XCTAssertEqual(
            RestoreTarget.decide(localExists: true, localSha: "A", dbRecordSha: nil), .divertToCopy)
    }
}
