import XCTest
import TideCore
@testable import Tide

/// `TransferProgress.reduce` の集約セマンティクス（begin/update/end + out-of-order 耐性）を固定する。
/// `SyncEngine.applyProgress` はこの純粋関数に委譲しているので、並行で前後し得るイベントの扱いをここで担保する。
final class TransferProgressTests: XCTestCase {
    private func begin(_ path: String, _ dir: TransferDirection, _ total: Int64) -> TransferProgressEvent {
        .begin(path: path, direction: dir, totalBytes: total)
    }
    private func update(_ path: String, _ dir: TransferDirection, _ done: Int64) -> TransferProgressEvent {
        .update(path: path, direction: dir, transferredBytes: done)
    }
    private func end(_ path: String, _ dir: TransferDirection) -> TransferProgressEvent {
        .end(path: path, direction: dir)
    }

    private func reduce(_ events: [TransferProgressEvent], from start: [TransferProgress] = []) -> [TransferProgress] {
        events.reduce(start) { TransferProgress.reduce($0, applying: $1) }
    }

    func testBeginCreatesEntry() {
        let list = reduce([begin("a.bin", .upload, 100)])
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].path, "a.bin")
        XCTAssertEqual(list[0].direction, .upload)
        XCTAssertEqual(list[0].transferredBytes, 0)
        XCTAssertEqual(list[0].totalBytes, 100)
    }

    func testBeginTwiceUpdatesTotalWithoutDuplicate() {
        let list = reduce([begin("a.bin", .upload, 100), update("a.bin", .upload, 40), begin("a.bin", .upload, 200)])
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].totalBytes, 200)
        XCTAssertEqual(list[0].transferredBytes, 40, "begin 再来でも進捗は保持する")
    }

    func testUpdateIncreasesOnly() {
        let list = reduce([begin("a.bin", .download, 100), update("a.bin", .download, 50), update("a.bin", .download, 30)])
        XCTAssertEqual(list[0].transferredBytes, 50, "後退する update は無視（out-of-order 耐性）")
    }

    func testUpdateEqualIsIgnored() {
        let list = reduce([begin("a.bin", .download, 100), update("a.bin", .download, 50), update("a.bin", .download, 50)])
        XCTAssertEqual(list[0].transferredBytes, 50)
    }

    func testUpdateOnMissingIsNoop() {
        // begin より前 / end より後に届いた update はエントリを復活させない。
        let list = reduce([update("ghost.bin", .upload, 10)])
        XCTAssertTrue(list.isEmpty)
    }

    func testEndRemovesEntry() {
        let list = reduce([begin("a.bin", .upload, 100), update("a.bin", .upload, 100), end("a.bin", .upload)])
        XCTAssertTrue(list.isEmpty)
    }

    func testLateUpdateAfterEndDoesNotResurrect() {
        // end 後に遅れて届いた update でゴーストが復活しないこと。
        let list = reduce([begin("a.bin", .upload, 100), end("a.bin", .upload), update("a.bin", .upload, 80)])
        XCTAssertTrue(list.isEmpty)
    }

    func testDirectionIndependence() {
        // 同じ path でも upload と download は別エントリ。
        let list = reduce([
            begin("shared.bin", .upload, 100), begin("shared.bin", .download, 200),
            update("shared.bin", .upload, 10), update("shared.bin", .download, 20),
            end("shared.bin", .upload),
        ])
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].direction, .download)
        XCTAssertEqual(list[0].transferredBytes, 20)
    }

    func testFraction() {
        var p = TransferProgress(path: "a", direction: .upload, transferredBytes: 0, totalBytes: 0)
        XCTAssertEqual(p.fraction, 0, "total 0 はゼロ除算回避で 0")
        p.totalBytes = 200
        p.transferredBytes = 50
        XCTAssertEqual(p.fraction, 0.25, accuracy: 1e-9)
        p.transferredBytes = 999
        XCTAssertEqual(p.fraction, 1, "1.0 にクランプ")
    }
}
