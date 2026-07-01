import TideCore
import Foundation

/// 非機密のアプリ設定を 1 つの JSON ファイルへ書き出し / 読み込みする（設定の export / import）。
/// 主目的はクリーンインストール後の復旧と、複数 Mac 間での設定の持ち回り。
///
/// 【セキュリティ不変条件】AWS 認証情報（Keychain）と `deviceId`（端末固有 ID）は **一切扱わない**。
/// export 対象は `ConfigStore` の非機密フィールドのみ。新しい Mac へ移すときは AWS キーを
/// セットアップウィザードで再入力する。これにより「認証情報は Data Protection Keychain のみ」
/// という不変条件を崩さない（`DiagnosticsExporter` と同じ姿勢）。
///
/// 接続設定（bucket / region / syncRoot）と tunables（polling / サイズ上限 / 帯域 / 通知）を
/// 分けて適用できるようにしている。接続の変更はローカル DB がバケットに紐づくためホットスワップ
/// せず、セットアップウィザードで再プロビジョニングする経路に限る（UI 側の責務）。
enum SettingsTransfer {

    /// 現在の payload スキーマ版。後方互換のため import 時にこの値以下のみ受理する。
    static let currentSchemaVersion = 1

    /// JSON で往復する非機密設定一式（純粋値・テスト可能）。
    /// 認証情報・`deviceId`・`setupCompleted` は **含めない**（構造的に漏れない）。
    struct Payload: Codable, Equatable, Sendable {
        var schemaVersion: Int
        /// 書き出し時刻（ISO8601 UTC・情報目的）。
        var exportedAt: String
        /// 書き出したアプリの版（"0.1.2 (12)" 形式・情報目的）。
        var appVersion: String?

        // 接続設定
        var bucketName: String?
        var region: String?
        var syncRootPath: String?

        // tunables
        var pollingIntervalSeconds: Int
        var uploadSizeLimitBytes: Int64
        var uploadBandwidthBytesPerSec: Int64
        var downloadBandwidthBytesPerSec: Int64
        var notificationsEnabled: Bool
    }

    enum TransferError: Error, LocalizedError {
        /// このアプリより新しいスキーマ版のファイルを読もうとした。
        case unsupportedVersion(found: Int, supported: Int)
        /// JSON として解釈できない / 必須フィールド欠落。
        case malformed

        var errorDescription: String? {
            switch self {
            case let .unsupportedVersion(found, supported):
                return String(localized: "This settings file (version \(found)) is newer than this app supports (version \(supported)).")
            case .malformed:
                return String(localized: "The settings file is not a valid Tide settings export.")
            }
        }
    }

    // MARK: - 純粋な encode / decode（テスト可能）

    /// payload を整形済み JSON にエンコードする。キー順を安定化して差分を読みやすくする。
    static func encode(_ payload: Payload) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(payload)
    }

    /// JSON をデコードし、スキーマ版を検証する。新しすぎる版は `unsupportedVersion` で拒否、
    /// 解釈不能は `malformed` に正規化する（呼び出し側が UI 文言に使える）。
    static func decode(_ data: Data) throws -> Payload {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw TransferError.malformed
        }
        guard payload.schemaVersion <= currentSchemaVersion else {
            throw TransferError.unsupportedVersion(found: payload.schemaVersion, supported: currentSchemaVersion)
        }
        return payload
    }

    // MARK: - ConfigStore との橋渡し（MainActor）

    /// 現在の設定から payload を組み立てる（認証情報・deviceId は構造的に含まれない）。
    @MainActor
    static func makePayload(from config: ConfigStore, generatedAt: Date, appVersion: String?) -> Payload {
        Payload(
            schemaVersion: currentSchemaVersion,
            exportedAt: ISO8601DateFormatter().string(from: generatedAt),
            appVersion: appVersion,
            bucketName: config.bucketName,
            region: config.region,
            syncRootPath: config.syncRootPath,
            pollingIntervalSeconds: config.pollingIntervalSeconds,
            uploadSizeLimitBytes: config.uploadSizeLimitBytes,
            uploadBandwidthBytesPerSec: config.uploadBandwidthBytesPerSec,
            downloadBandwidthBytesPerSec: config.downloadBandwidthBytesPerSec,
            notificationsEnabled: config.notificationsEnabled
        )
    }

    /// import した payload を **すべて**（接続 + tunables）ConfigStore に反映する。
    /// `deviceId` / `setupCompleted` / 認証情報は触らない。
    /// 接続設定の書き込みを伴うので、エンジン未起動の経路（セットアップウィザード）でのみ使う。
    @MainActor
    static func apply(_ payload: Payload, to config: ConfigStore) {
        config.bucketName = payload.bucketName
        config.region = payload.region
        config.syncRootPath = payload.syncRootPath
        applyTunables(payload, to: config)
    }

    /// tunables（polling / サイズ上限 / 帯域 / 通知）だけを反映する。接続設定は触らない。
    /// エンジン稼働中（Settings 画面）でも安全に即適用できる部分集合。
    @MainActor
    static func applyTunables(_ payload: Payload, to config: ConfigStore) {
        config.pollingIntervalSeconds = payload.pollingIntervalSeconds
        config.uploadSizeLimitBytes = payload.uploadSizeLimitBytes
        config.uploadBandwidthBytesPerSec = payload.uploadBandwidthBytesPerSec
        config.downloadBandwidthBytesPerSec = payload.downloadBandwidthBytesPerSec
        config.notificationsEnabled = payload.notificationsEnabled
    }

    // MARK: - IO

    /// 現在の設定を `destination` に JSON で書き出す。出力先は呼び出し側が NSSavePanel で選んだ場所のみ。
    @MainActor
    static func export(to destination: URL, config: ConfigStore) throws {
        let payload = makePayload(from: config, generatedAt: Date(), appVersion: Self.appVersionString())
        let data = try encode(payload)
        try data.write(to: destination, options: .atomic)
    }

    /// `source` から JSON を読み、検証済み payload を返す。入力元は呼び出し側が NSOpenPanel で選んだ場所のみ。
    static func read(from source: URL) throws -> Payload {
        let data: Data
        do {
            data = try Data(contentsOf: source)
        } catch {
            throw TransferError.malformed
        }
        return try decode(data)
    }

    /// "x.y.z (build)" 形式のアプリ版文字列（情報目的）。取得できなければ nil。
    @MainActor
    private static func appVersionString() -> String? {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (s?, b?): return "\(s) (\(b))"
        case let (s?, nil): return s
        default: return nil
        }
    }
}
