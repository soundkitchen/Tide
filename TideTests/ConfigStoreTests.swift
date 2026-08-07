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

    /// 契約キーの往復保証。Swift プロパティの往復に加えて**リテラルのキー名・保存値**を生の
    /// UserDefaults に対して固定する — `tools/soak/consistency_check.py` は
    /// `defaults read … tide.syncMode` の生文字列を読むため、`Key.syncMode` のリネームや
    /// rawValue の変更はプロパティ経由の往復だけでは検出できない（PR #100 レビュー指摘 6）。
    func testSyncModeRoundTrip() {
        let suite = "tide-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let config = ConfigStore(defaults: defaults)
        config.syncMode = .fpOnly
        XCTAssertEqual(config.syncMode, .fpOnly)
        XCTAssertEqual(defaults.string(forKey: "tide.syncMode"), "fpOnly")
        config.syncMode = .folderSync
        XCTAssertEqual(config.syncMode, .folderSync)
        XCTAssertEqual(defaults.string(forKey: "tide.syncMode"), "folderSync")
    }

    /// キー不在 / 未知の保存値 → `.folderSync` フォールバックの固定（PR #100 レビュー指摘 5）。
    /// このフォールバックは #96 正規化書込の前提（load-bearing）: bootstrap は
    /// `syncMode != .fpOnly` のときだけ書き戻すため、不在を `.fpOnly` と読むよう「掃除」すると
    /// 正規化が一度も書かれず、外部ツールは生 defaults 不在 → "folderSync" と解釈して
    /// DB 凍結見張りが静かに非武装化する。`?? .fpOnly` へ変えてはならない。
    func testSyncModeMissingOrUnknownKeyFallsBackToFolderSync() {
        let suite = "tide-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let config = ConfigStore(defaults: defaults)
        XCTAssertEqual(config.syncMode, .folderSync)          // キー不在
        defaults.set("someFutureMode", forKey: "tide.syncMode")
        XCTAssertEqual(config.syncMode, .folderSync)          // 未知の保存値
    }
}
