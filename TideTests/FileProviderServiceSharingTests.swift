import XCTest
import TideCore

/// FP 拡張のサービスをプロセスで共有するときの、作り直す段の判定（Issue #151・PR #157 レビュー指摘 8）。
/// 変わった値の段とその下の段だけを作り直し、上の段は使い回すことを固定する。
final class FileProviderServiceSharingTests: XCTestCase {
    private typealias Sharing = FileProviderServiceSharing

    private func key(
        domainIdentifier: String = "main2",
        domainEpoch: String? = "epoch-1",
        bucket: String = "dev-tide",
        region: String = "ap-northeast-1",
        deviceId: String = "device-1",
        credentials: AWSCredentials = AWSCredentials(accessKeyId: "AKIA1", secretAccessKey: "secret-1"),
        uploadSizeLimitBytes: Int64 = 0,
        uploadBandwidthBytesPerSec: Int64 = 0
    ) -> Sharing.Key {
        Sharing.Key(
            state: .init(domainIdentifier: domainIdentifier, domainEpoch: domainEpoch, bucket: bucket),
            connection: .init(
                region: region, deviceId: deviceId,
                credentialsDigest: Sharing.credentialsDigest(credentials)),
            writer: .init(
                uploadSizeLimitBytes: uploadSizeLimitBytes,
                uploadBandwidthBytesPerSec: uploadBandwidthBytesPerSec))
    }

    private let reuseAll = Sharing.Plan(reuseState: true, reuseConnection: true, reuseWriter: true)
    private let rebuildWriter = Sharing.Plan(reuseState: true, reuseConnection: true, reuseWriter: false)
    private let rebuildConnection = Sharing.Plan(reuseState: true, reuseConnection: false, reuseWriter: false)
    private let rebuildAll = Sharing.Plan(reuseState: false, reuseConnection: false, reuseWriter: false)

    func testFirstInstanceBuildsEverything() {
        XCTAssertEqual(Sharing.plan(cached: nil, new: key()), rebuildAll)
    }

    func testSameValuesReuseEverything() {
        XCTAssertEqual(Sharing.plan(cached: key(), new: key()), reuseAll)
    }

    /// 帯域・上限の変更（設定画面のふつうの操作）では、コアレッサとレジストリを作り直さない。
    func testWriterSettingsRebuildOnlyWriter() {
        XCTAssertEqual(Sharing.plan(cached: key(), new: key(uploadBandwidthBytesPerSec: 1_000_000)), rebuildWriter)
        XCTAssertEqual(Sharing.plan(cached: key(), new: key(uploadSizeLimitBytes: 5_000_000)), rebuildWriter)
    }

    /// 認証情報・deviceId・リージョンの変更では接続（S3 クライアント・キャッシュ・コアレッサ）を
    /// 作り直すが、レジストリは使い回す。
    func testConnectionValuesRebuildConnectionAndWriterButKeepState() {
        XCTAssertEqual(Sharing.plan(cached: key(), new: key(deviceId: "device-2")), rebuildConnection)
        XCTAssertEqual(Sharing.plan(cached: key(), new: key(region: "us-east-1")), rebuildConnection)
        XCTAssertEqual(
            Sharing.plan(cached: key(), new: key(credentials: AWSCredentials(accessKeyId: "AKIA2", secretAccessKey: "secret-1"))),
            rebuildConnection)
        XCTAssertEqual(
            Sharing.plan(cached: key(), new: key(credentials: AWSCredentials(accessKeyId: "AKIA1", secretAccessKey: "secret-2"))),
            rebuildConnection)
    }

    /// ドメインの作り直し（epoch）・識別子・バケットの変更では全段を作り直す。
    func testStateValuesRebuildEverything() {
        XCTAssertEqual(Sharing.plan(cached: key(), new: key(domainEpoch: "epoch-2")), rebuildAll)
        XCTAssertEqual(Sharing.plan(cached: key(), new: key(domainEpoch: nil)), rebuildAll)
        XCTAssertEqual(Sharing.plan(cached: key(), new: key(domainIdentifier: "main3")), rebuildAll)
        XCTAssertEqual(Sharing.plan(cached: key(), new: key(bucket: "prod-tide")), rebuildAll)
    }

    /// 比較用の値はシークレットを平文で含まず、シークレットの入れ替えは見分ける。
    func testCredentialsDigestHidesSecretButDistinguishesIt() {
        let digest = Sharing.credentialsDigest(AWSCredentials(accessKeyId: "AKIA1", secretAccessKey: "secret-1"))
        XCTAssertFalse(digest.contains("secret-1"))
        XCTAssertTrue(digest.hasPrefix("AKIA1:"))
        XCTAssertNotEqual(
            digest, Sharing.credentialsDigest(AWSCredentials(accessKeyId: "AKIA1", secretAccessKey: "secret-2")))
    }
}
