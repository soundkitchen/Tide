import XCTest
import GRDB
import TideCore
@testable import Tide

final class SyncIssueClassifierTests: XCTestCase {
    /// `String(describing:)` の内容で分類する実装に合わせ、説明文を差し替えた擬似エラー
    /// （`S3ErrorClassifierTests` と同じ流儀）。
    private struct FakeError: Error, CustomStringConvertible {
        let description: String
    }

    private struct UnknownError: Error {}

    // MARK: - SyncError の直マップ

    func testSyncErrorDirectMapping() {
        XCTAssertEqual(
            SyncIssueClassifier.category(for: SyncError.fileTooLarge(path: "a.bin", size: 1)),
            .fileTooLarge
        )
        XCTAssertEqual(
            SyncIssueClassifier.category(for: SyncError.fileChangedDuringUpload(path: "a.bin")),
            .unstableFile
        )
        XCTAssertEqual(
            SyncIssueClassifier.category(for: SyncError.ioError(underlying: UnknownError())),
            .localIO
        )
        XCTAssertEqual(
            SyncIssueClassifier.category(for: SyncError.databaseError(underlying: UnknownError())),
            .database
        )
        XCTAssertEqual(
            SyncIssueClassifier.category(for: SyncError.manifestUpdateFailed("CAS failed")),
            .remoteConflict
        )
    }

    func testSyncErrorConfigurationGroup() {
        XCTAssertEqual(SyncIssueClassifier.category(for: SyncError.notConfigured()), .configuration)
        XCTAssertEqual(SyncIssueClassifier.category(for: SyncError.invalidSyncRoot("missing")), .configuration)
        XCTAssertEqual(SyncIssueClassifier.category(for: SyncError.versioningNotEnabled), .configuration)
        XCTAssertEqual(
            SyncIssueClassifier.category(for: SyncError.bucketNotAccessible(reason: "403")),
            .configuration
        )
        XCTAssertEqual(SyncIssueClassifier.category(for: SyncError.keychain(status: -34018)), .configuration)
    }

    // MARK: - awsError は underlying を剥がして分類

    func testAwsErrorUnwrapsUnderlying() {
        let forbidden = SyncError.awsError(underlying: FakeError(description: "AccessDenied"))
        XCTAssertEqual(SyncIssueClassifier.category(for: forbidden), .accessDenied)

        let notFound = SyncError.awsError(underlying: FakeError(description: "NoSuchKey"))
        XCTAssertEqual(SyncIssueClassifier.category(for: notFound), .notFound)

        let timeout = SyncError.awsError(underlying: URLError(.timedOut))
        XCTAssertEqual(SyncIssueClassifier.category(for: timeout), .network)
    }

    // MARK: - S3 固有コード（S3ErrorClassifier 委譲）

    func testS3Classification() {
        XCTAssertEqual(SyncIssueClassifier.category(for: FakeError(description: "statusCode: 403")), .accessDenied)
        XCTAssertEqual(SyncIssueClassifier.category(for: FakeError(description: "status code: 404")), .notFound)
        XCTAssertEqual(SyncIssueClassifier.category(for: FakeError(description: "NoSuchBucket")), .notFound)
        XCTAssertEqual(
            SyncIssueClassifier.category(for: FakeError(description: "PreconditionFailed 412")),
            .remoteConflict
        )
        XCTAssertEqual(
            SyncIssueClassifier.category(for: FakeError(description: "ConditionalRequestConflict, HTTP status code: 409")),
            .remoteConflict
        )
    }

    // MARK: - ネットワーク

    func testNetworkClassification() {
        XCTAssertEqual(SyncIssueClassifier.category(for: URLError(.notConnectedToInternet)), .network)
        XCTAssertEqual(SyncIssueClassifier.category(for: URLError(.timedOut)), .network)
        XCTAssertEqual(
            SyncIssueClassifier.category(for: FakeError(description: "The request timed out.")),
            .network
        )
        XCTAssertEqual(
            SyncIssueClassifier.category(for: FakeError(description: "crtError(code: 1059)")),
            .network
        )
        XCTAssertEqual(
            SyncIssueClassifier.category(for: FakeError(description: "The network connection was lost.")),
            .network
        )
    }

    // MARK: - ローカル系の型マッチ

    func testLocalErrorTypes() {
        XCTAssertEqual(
            SyncIssueClassifier.category(for: CocoaError(.fileReadNoSuchFile)),
            .localIO
        )
        XCTAssertEqual(SyncIssueClassifier.category(for: FileOpenError.isSymbolicLink), .localIO)
        XCTAssertEqual(
            SyncIssueClassifier.category(for: DatabaseError(resultCode: .SQLITE_BUSY)),
            .database
        )
    }

    /// 型マッチが文字列ヒューリスティックより先に確定する（PR #17 レビュー Low-1）。
    /// 説明文に "412" / "offline" を含むローカルエラーが remoteConflict / network に
    /// 誤分類されないことを固定する。
    func testTypeMatchBeatsStringHeuristics() {
        // GRDB DatabaseError: message に "412" と "offline" を含めても database のまま。
        let dbError = DatabaseError(
            resultCode: .SQLITE_IOERR,
            message: "disk I/O error at offline-412.sqlite (PreconditionFailed-like text)"
        )
        XCTAssertTrue(
            String(describing: dbError).contains("412"),
            "前提: 説明文に 412 が含まれている（含まれないならこのテストは無意味）"
        )
        XCTAssertEqual(SyncIssueClassifier.category(for: dbError), .database)

        // CocoaError(file 系): userInfo のパスに "offline" / "412" を含めても localIO のまま。
        let cocoaError = CocoaError(
            .fileReadNoSuchFile,
            userInfo: [NSFilePathErrorKey: "/tmp/offline-report-412.txt"]
        )
        XCTAssertEqual(SyncIssueClassifier.category(for: cocoaError), .localIO)

        // URLError: userInfo に S3 風の語を含めても network のまま。
        var urlInfo: [String: Any] = [:]
        urlInfo[NSLocalizedDescriptionKey] = "AccessDenied-like 412 message"
        let urlError = URLError(.cannotConnectToHost, userInfo: urlInfo)
        XCTAssertEqual(SyncIssueClassifier.category(for: urlError), .network)
    }

    // MARK: - フォールバック

    func testUnknownErrorFallsBackToOther() {
        XCTAssertEqual(SyncIssueClassifier.category(for: UnknownError()), .other)
        XCTAssertEqual(SyncIssueClassifier.category(for: FakeError(description: "something exploded")), .other)
    }

    // MARK: - classify の組み立て

    func testClassifyPassesThroughPathAndDate() {
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        let issue = SyncIssueClassifier.classify(
            error: FakeError(description: "AccessDenied"), path: "docs/a.txt", date: date
        )
        XCTAssertEqual(issue.category, .accessDenied)
        XCTAssertEqual(issue.path, "docs/a.txt")
        XCTAssertEqual(issue.date, date)
        XCTAssertEqual(issue.rawDetail, "AccessDenied")
    }

    func testClassifyUsesSyncErrorDescriptionAsRawDetail() {
        let error = SyncError.fileTooLarge(path: "big.zip", size: 123)
        let issue = SyncIssueClassifier.classify(error: error, path: "big.zip")
        // CustomStringConvertible の description（path / size 込み）を生詳細として保持する。
        XCTAssertEqual(issue.rawDetail, error.description)
        XCTAssertTrue(issue.rawDetail.contains("big.zip"))
    }
}
