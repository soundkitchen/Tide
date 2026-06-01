import XCTest
@testable import Tide

final class PartPlanTests: XCTestCase {
    func testSinglePartBelowThreshold() {
        XCTAssertFalse(PartPlan.shouldUseMultipart(fileSize: 1))
        XCTAssertFalse(PartPlan.shouldUseMultipart(fileSize: PartPlan.multipartThreshold))
        XCTAssertTrue(PartPlan.shouldUseMultipart(fileSize: PartPlan.multipartThreshold + 1))
    }

    func testPlanUsesMinPartSizeForModestFiles() {
        // 数十 MiB は最小パートサイズ 5 MiB のまま
        let p = PartPlan.plan(forFileSize: 20 * 1024 * 1024)  // 20 MiB
        XCTAssertEqual(p.partSize, 5 * 1024 * 1024)
        XCTAssertEqual(p.partCount, 4)
    }

    func testPlanStaysUnderMaxPartsAndIsMiBAligned() {
        let sizes: [Int64] = [
            1 * 1024 * 1024 * 1024,         // 1 GiB
            50 * 1024 * 1024 * 1024,        // 50 GiB
            5 * 1024 * 1024 * 1024 * 1024,  // 5 TiB (S3 単一オブジェクト上限)
        ]
        let oneMiB: Int64 = 1024 * 1024
        for s in sizes {
            let p = PartPlan.plan(forFileSize: s)
            XCTAssertLessThanOrEqual(p.partCount, PartPlan.maxPartCount, "size=\(s)")
            XCTAssertGreaterThanOrEqual(p.partSize, PartPlan.minPartSize)
            XCTAssertEqual(Int64(p.partSize) % oneMiB, 0, "partSize must be MiB-aligned: \(p.partSize)")
            // 全パートでファイル全体を覆える
            XCTAssertGreaterThanOrEqual(Int64(p.partCount) * Int64(p.partSize), s, "size=\(s)")
        }
    }

    func testPartSizeGrowsForHugeFiles() {
        let modest = PartPlan.plan(forFileSize: 20 * 1024 * 1024)
        let huge = PartPlan.plan(forFileSize: 50 * 1024 * 1024 * 1024)
        XCTAssertGreaterThan(huge.partSize, modest.partSize)
    }

    func testUploadLimit() {
        XCTAssertTrue(PartPlan.isWithinUploadLimit(size: 100, limitBytes: -1))   // 無制限センチネル
        XCTAssertTrue(PartPlan.isWithinUploadLimit(size: 100, limitBytes: 0))    // 0 も無制限扱い
        XCTAssertTrue(PartPlan.isWithinUploadLimit(size: 100, limitBytes: 100))  // 境界 OK
        XCTAssertFalse(PartPlan.isWithinUploadLimit(size: 101, limitBytes: 100)) // 超過
    }
}
