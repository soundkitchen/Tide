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

    /// pollingIntervalSeconds: 0 = 未設定 → 既定 180、明示値は下限 30 へクランプ
    /// （負値/極小値の保存で pull / RemoteChangeSignaler の HEAD が密ループ化するのを防ぐ・
    /// PR #75 レビュー任意 2）。
    func testPollingIntervalClampsToSafeRange() {
        let config = makeStore()
        XCTAssertEqual(config.pollingIntervalSeconds, 180)   // 未設定 → 既定
        config.pollingIntervalSeconds = 60
        XCTAssertEqual(config.pollingIntervalSeconds, 60)    // 通常値はそのまま
        config.pollingIntervalSeconds = 5
        XCTAssertEqual(config.pollingIntervalSeconds, 30)    // 極小値は下限へ
        config.pollingIntervalSeconds = -1
        XCTAssertEqual(config.pollingIntervalSeconds, 30)    // 負値も下限へ
    }

    // MARK: - syncMode（v0.3.0 #96〜 = 外部ツール契約キー。アプリは分岐のために読まない）

    /// 契約キーとしての保存値の往復保証（`tools/soak/consistency_check.py` が保存値を読むため、
    /// enum rawValue と UserDefaults キーの対応が壊れていないことを固定する）。
    /// 旧「folderSync = 安全側既定」セマンティクスのテスト（既定値 / 未知値フォールバック /
    /// reset でのクリア）は v0.3.0 で意味が反転した（bootstrap の正規化書込が常に fpOnly へ
    /// 上書きする）ため削除した（#96）。
    func testSyncModeRoundTrip() {
        let config = makeStore()
        config.syncMode = .fpOnly
        XCTAssertEqual(config.syncMode, .fpOnly)
        config.syncMode = .folderSync
        XCTAssertEqual(config.syncMode, .folderSync)
    }
}
