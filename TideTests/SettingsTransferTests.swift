import XCTest
@testable import Tide

final class SettingsTransferTests: XCTestCase {

    /// テスト専用の分離した UserDefaults スイートで ConfigStore を作る（ConfigStoreTests と同流儀）。
    @MainActor
    private func makeStore() -> ConfigStore {
        let suite = "tide-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        return ConfigStore(defaults: defaults)
    }

    private func samplePayload(schemaVersion: Int = SettingsTransfer.currentSchemaVersion) -> SettingsTransfer.Payload {
        SettingsTransfer.Payload(
            schemaVersion: schemaVersion,
            exportedAt: "2026-06-30T00:00:00Z",
            appVersion: "0.1.2 (12)",
            bucketName: "my-bucket",
            region: "ap-northeast-1",
            syncRootPath: "/Users/test/Sync",
            pollingIntervalSeconds: 300,
            uploadSizeLimitBytes: 50 * 1024 * 1024 * 1024,
            uploadBandwidthBytesPerSec: 10_000_000,
            downloadBandwidthBytesPerSec: -1,
            notificationsEnabled: false
        )
    }

    // MARK: - encode / decode

    func testEncodeDecodeRoundTrip() throws {
        let payload = samplePayload()
        let data = try SettingsTransfer.encode(payload)
        let decoded = try SettingsTransfer.decode(data)
        XCTAssertEqual(decoded, payload)
    }

    func testDecodeRejectsNewerSchemaVersion() throws {
        let future = samplePayload(schemaVersion: SettingsTransfer.currentSchemaVersion + 1)
        let data = try SettingsTransfer.encode(future)
        XCTAssertThrowsError(try SettingsTransfer.decode(data)) { error in
            guard case SettingsTransfer.TransferError.unsupportedVersion = error else {
                return XCTFail("Expected unsupportedVersion, got \(error)")
            }
        }
    }

    func testDecodeRejectsMalformedJSON() {
        let garbage = Data("not a tide settings file".utf8)
        XCTAssertThrowsError(try SettingsTransfer.decode(garbage)) { error in
            guard case SettingsTransfer.TransferError.malformed = error else {
                return XCTFail("Expected malformed, got \(error)")
            }
        }
    }

    /// export した JSON に認証情報・deviceId が構造的に含まれないことを担保する。
    @MainActor
    func testEncodedPayloadHasNoSecretsOrDeviceId() throws {
        let config = makeStore()
        config.bucketName = "my-bucket"
        config.region = "ap-northeast-1"
        config.syncRootPath = "/Users/test/Sync"
        _ = config.deviceId  // deviceId を生成させておく
        let payload = SettingsTransfer.makePayload(from: config, generatedAt: Date(), appVersion: nil)
        let json = String(decoding: try SettingsTransfer.encode(payload), as: UTF8.self)
        XCTAssertFalse(json.contains("deviceId"))
        XCTAssertFalse(json.lowercased().contains("accesskey"))
        XCTAssertFalse(json.lowercased().contains("secret"))
        XCTAssertFalse(json.contains(config.deviceId))
    }

    // MARK: - makePayload / apply

    @MainActor
    func testMakePayloadReflectsConfig() {
        let config = makeStore()
        config.bucketName = "b"
        config.region = "us-east-1"
        config.syncRootPath = "/tmp/x"
        config.pollingIntervalSeconds = 120
        config.uploadSizeLimitBytes = -1
        config.uploadBandwidthBytesPerSec = 2_000_000
        config.downloadBandwidthBytesPerSec = 3_000_000
        config.notificationsEnabled = false

        let p = SettingsTransfer.makePayload(from: config, generatedAt: Date(), appVersion: "x")
        XCTAssertEqual(p.schemaVersion, SettingsTransfer.currentSchemaVersion)
        XCTAssertEqual(p.bucketName, "b")
        XCTAssertEqual(p.region, "us-east-1")
        XCTAssertEqual(p.syncRootPath, "/tmp/x")
        XCTAssertEqual(p.pollingIntervalSeconds, 120)
        XCTAssertEqual(p.uploadSizeLimitBytes, -1)
        XCTAssertEqual(p.uploadBandwidthBytesPerSec, 2_000_000)
        XCTAssertEqual(p.downloadBandwidthBytesPerSec, 3_000_000)
        XCTAssertFalse(p.notificationsEnabled)
    }

    @MainActor
    func testApplySetsAllFieldsAndKeepsDeviceId() {
        let config = makeStore()
        let originalDeviceId = config.deviceId  // 生成 & 固定
        SettingsTransfer.apply(samplePayload(), to: config)

        XCTAssertEqual(config.bucketName, "my-bucket")
        XCTAssertEqual(config.region, "ap-northeast-1")
        XCTAssertEqual(config.syncRootPath, "/Users/test/Sync")
        XCTAssertEqual(config.pollingIntervalSeconds, 300)
        XCTAssertEqual(config.uploadSizeLimitBytes, 50 * 1024 * 1024 * 1024)
        XCTAssertEqual(config.uploadBandwidthBytesPerSec, 10_000_000)
        XCTAssertEqual(config.downloadBandwidthBytesPerSec, -1)
        XCTAssertFalse(config.notificationsEnabled)
        // deviceId / setupCompleted は import 対象外
        XCTAssertEqual(config.deviceId, originalDeviceId)
        XCTAssertFalse(config.setupCompleted)
    }

    @MainActor
    func testApplyTunablesLeavesConnectionUntouched() {
        let config = makeStore()
        config.bucketName = "current-bucket"
        config.region = "current-region"
        config.syncRootPath = "/current/path"

        SettingsTransfer.applyTunables(samplePayload(), to: config)

        // 接続設定は不変
        XCTAssertEqual(config.bucketName, "current-bucket")
        XCTAssertEqual(config.region, "current-region")
        XCTAssertEqual(config.syncRootPath, "/current/path")
        // tunables は反映
        XCTAssertEqual(config.pollingIntervalSeconds, 300)
        XCTAssertEqual(config.uploadSizeLimitBytes, 50 * 1024 * 1024 * 1024)
        XCTAssertFalse(config.notificationsEnabled)
    }
}
