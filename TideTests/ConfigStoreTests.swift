import XCTest
import TideCore
@testable import Tide

final class ConfigStoreTests: XCTestCase {
    /// テスト専用の分離した UserDefaults スイートで ConfigStore を作る。
    private func makeStore() -> ConfigStore {
        let suite = "tide-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock {
            // suite 名（Sendable）だけをキャプチャして後始末する。
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        return ConfigStore(defaults: defaults)
    }

    func testUploadSizeLimitDefaultsTo1GiB() {
        let config = makeStore()
        XCTAssertEqual(config.uploadSizeLimitBytes, ConfigStore.defaultUploadSizeLimitBytes)
        XCTAssertEqual(config.uploadSizeLimitBytes, 1 * 1024 * 1024 * 1024)
    }

    func testUploadSizeLimitRoundTripLargeValue() {
        let config = makeStore()
        let fiftyGiB: Int64 = 50 * 1024 * 1024 * 1024
        config.uploadSizeLimitBytes = fiftyGiB
        XCTAssertEqual(config.uploadSizeLimitBytes, fiftyGiB)
    }

    func testUploadSizeLimitUnlimitedSentinel() {
        let config = makeStore()
        config.uploadSizeLimitBytes = -1
        XCTAssertEqual(config.uploadSizeLimitBytes, -1)
        XCTAssertTrue(PartPlan.isWithinUploadLimit(size: .max, limitBytes: config.uploadSizeLimitBytes))
    }

    func testResetRestoresDefaultLimit() {
        let config = makeStore()
        config.uploadSizeLimitBytes = 10 * 1024 * 1024 * 1024
        config.reset()
        XCTAssertEqual(config.uploadSizeLimitBytes, ConfigStore.defaultUploadSizeLimitBytes)
    }
}
