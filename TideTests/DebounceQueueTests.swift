import XCTest
import TideCore
@testable import Tide

final class DebounceQueueTests: XCTestCase {
    func testConsecutiveEventsCoalesce() async throws {
        let received = OutputCollector<String>()
        let q = DebounceQueue<String>(interval: 0.1) { key, value in
            await received.append("\(key)=\(value)")
        }
        await q.submit(key: "a", value: "1")
        await q.submit(key: "a", value: "2")
        await q.submit(key: "a", value: "3")
        try await Task.sleep(for: .milliseconds(300))
        let all = await received.snapshot()
        XCTAssertEqual(all, ["a=3"])
    }

    func testIndependentKeysFlushIndependently() async throws {
        let received = OutputCollector<String>()
        let q = DebounceQueue<String>(interval: 0.05) { key, value in
            await received.append("\(key)=\(value)")
        }
        await q.submit(key: "x", value: "X")
        await q.submit(key: "y", value: "Y")
        try await Task.sleep(for: .milliseconds(200))
        let all = await received.snapshot().sorted()
        XCTAssertEqual(all, ["x=X", "y=Y"])
    }

    func testLastValueWins() async throws {
        let received = OutputCollector<String>()
        let q = DebounceQueue<String>(interval: 0.05) { key, value in
            await received.append("\(key)=\(value)")
        }
        await q.submit(key: "p", value: "first")
        try await Task.sleep(for: .milliseconds(20))
        await q.submit(key: "p", value: "last")
        try await Task.sleep(for: .milliseconds(200))
        let all = await received.snapshot()
        XCTAssertEqual(all, ["p=last"])
    }
}

actor OutputCollector<T: Sendable> {
    private var items: [T] = []
    func append(_ x: T) { items.append(x) }
    func snapshot() -> [T] { items }
}
