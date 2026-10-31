import CryptoKit
import Foundation

/// FP 拡張のサービスをプロセスで共有するときの、作り直す段の判定（Issue #151）。
///
/// fileproviderd は同じプロセスの中で拡張のインスタンスを作り直し、見限った古いインスタンスが
/// 処理中の書込を抱えたまま新しいインスタンスと同居することがある。サービスを作り直すと、同じ
/// プロセスにコアレッサやレジストリが 2 つずつでき、index.json の奪い合い・同じ JSON の上書きが
/// 起きる。そこでサービスを 3 段に分け、変わった値に応じて必要な段だけを作り直す:
///
/// - 段 ① 状態（`StateKey`）: レジストリ 5 本・実体化の観測・イベントログ。ドメイン・epoch・
///   バケットが同じ限り作り直さない（レジストリの予約を上書きで落とさない）。
/// - 段 ② 接続（`ConnectionKey`）: S3 クライアント・マニフェストのキャッシュ・書込の
///   `ManifestUpdater`（= `IndexUpdateCoalescer`）・`.syncignore` のキャッシュ。リージョン・
///   deviceId・認証情報が変わったときだけ作り直す。
/// - 段 ③ 書き手（`WriterKey`）: アップロードの上限・帯域。段 ② を使い回したまま書き手だけを作る
///   （帯域・上限の変更では奪い合いが起きない）。
///
/// 上の段を作り直すときは、下の段もすべて作り直す（段 ② は段 ① のドメインへ signal し、
/// 段 ③ は段 ② の S3 クライアントと updater で書く）。
public enum FileProviderServiceSharing {
    public struct StateKey: Equatable, Sendable {
        public let domainIdentifier: String
        public let domainEpoch: String?
        public let bucket: String

        public init(domainIdentifier: String, domainEpoch: String?, bucket: String) {
            self.domainIdentifier = domainIdentifier
            self.domainEpoch = domainEpoch
            self.bucket = bucket
        }
    }

    public struct ConnectionKey: Equatable, Sendable {
        public let region: String
        public let deviceId: String
        /// 認証情報の比較用の値（`credentialsDigest`）。シークレットを平文で持たない。
        public let credentialsDigest: String

        public init(region: String, deviceId: String, credentialsDigest: String) {
            self.region = region
            self.deviceId = deviceId
            self.credentialsDigest = credentialsDigest
        }
    }

    public struct WriterKey: Equatable, Sendable {
        public let uploadSizeLimitBytes: Int64
        public let uploadBandwidthBytesPerSec: Int64

        public init(uploadSizeLimitBytes: Int64, uploadBandwidthBytesPerSec: Int64) {
            self.uploadSizeLimitBytes = uploadSizeLimitBytes
            self.uploadBandwidthBytesPerSec = uploadBandwidthBytesPerSec
        }
    }

    public struct Key: Equatable, Sendable {
        public let state: StateKey
        public let connection: ConnectionKey
        public let writer: WriterKey

        public init(state: StateKey, connection: ConnectionKey, writer: WriterKey) {
            self.state = state
            self.connection = connection
            self.writer = writer
        }
    }

    /// どの段を使い回すか。上の段を作り直すときは下の段も使い回さない。
    public struct Plan: Equatable, Sendable {
        public let reuseState: Bool
        public let reuseConnection: Bool
        public let reuseWriter: Bool

        public init(reuseState: Bool, reuseConnection: Bool, reuseWriter: Bool) {
            self.reuseState = reuseState
            self.reuseConnection = reuseConnection
            self.reuseWriter = reuseWriter
        }
    }

    public static func plan(cached: Key?, new: Key) -> Plan {
        let reuseState = cached?.state == new.state
        let reuseConnection = reuseState && cached?.connection == new.connection
        let reuseWriter = reuseConnection && cached?.writer == new.writer
        return Plan(reuseState: reuseState, reuseConnection: reuseConnection, reuseWriter: reuseWriter)
    }

    /// サービスを作れなかった理由（Issue #158）。
    public enum Unavailable: Equatable, Sendable {
        /// 未セットアップ（setupCompleted が false・バケット / リージョンが無い）。factoryReset のあとなど。
        case notConfigured
        /// Keychain に認証情報が無い（`KeychainStore.load()` が nil）。
        case missingCredentials
        /// Keychain の読み取りが失敗した（`KeychainStore.load()` が throw = 一時的な失敗）。
        case credentialsReadFailed
    }

    /// サービスを作れなかったときに、認証情報を持つ段（② 接続・③ 書き手）を共有の置き場から外すか。
    ///
    /// 設定が本当に欠けたとき（未セットアップ・認証情報が無い）は外す。Keychain の読み取りの一時的な
    /// 失敗では外さない — 外すと次のインスタンスが段 ② を作り直し、書込を抱えた古いインスタンスと
    /// 同じプロセスにコアレッサとキャッシュが 2 つできて index.json を奪い合う（#151 と同じ構図）。
    /// 認証情報が入れ替わっていれば、読み取りが戻ったあとのキーの比較で段 ② は作り直される。
    public static func dropsConnection(when reason: Unavailable) -> Bool {
        switch reason {
        case .notConfigured, .missingCredentials: true
        case .credentialsReadFailed: false
        }
    }

    /// 認証情報の比較用の値 = アクセスキー ID + シークレットの SHA-256。シークレットの入れ替えも
    /// 見分けつつ、共有の置き場にシークレットを平文で持たない（PR #157 レビュー指摘 6）。
    public static func credentialsDigest(_ credentials: AWSCredentials) -> String {
        let secretHash = SHA256.hash(data: Data(credentials.secretAccessKey.utf8))
        return credentials.accessKeyId + ":" + secretHash.map { String(format: "%02x", $0) }.joined()
    }
}
