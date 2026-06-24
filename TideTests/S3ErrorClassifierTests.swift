import XCTest
@testable import Tide

final class S3ErrorClassifierTests: XCTestCase {
    /// `String(describing:)` の内容で分類する実装に合わせ、説明文を差し替えた擬似エラー。
    private struct FakeError: Error, CustomStringConvertible {
        let description: String
    }

    func testInconclusiveHeadError() {
        // HeadBucket の空ボディ非 404 → smithy が missingRequiredData を投げる
        XCTAssertTrue(S3ErrorClassifier.isInconclusiveHeadError(FakeError(description: "missingRequiredData")))
        XCTAssertFalse(S3ErrorClassifier.isInconclusiveHeadError(FakeError(description: "NoSuchBucket")))
    }

    func testAlreadyOwnedByYouIsNotNameTaken() {
        let e = FakeError(description: "BucketAlreadyOwnedByYou(message: \"...\")")
        XCTAssertTrue(S3ErrorClassifier.isBucketAlreadyOwnedByYou(e))
        XCTAssertFalse(S3ErrorClassifier.isBucketNameTaken(e))
    }

    func testNameTakenIsNotOwnedByYou() {
        let e = FakeError(description: "BucketAlreadyExists(message: \"...\")")
        XCTAssertTrue(S3ErrorClassifier.isBucketNameTaken(e))
        XCTAssertFalse(S3ErrorClassifier.isBucketAlreadyOwnedByYou(e))
    }

    func testConditionalConflictIsRetryable() {
        // 409 ConditionalRequestConflict（同一キーへの並行条件付き PUT 衝突）
        let e = FakeError(description: "UnknownAWSHTTPServiceError(typeName: Optional(\"ConditionalRequestConflict\"), message: ..., HTTP status code: 409")
        XCTAssertTrue(S3ErrorClassifier.isConditionalConflict(e))
        // 412 とは別物だが、どちらもリトライ対象
        XCTAssertFalse(S3ErrorClassifier.isConditionalConflict(FakeError(description: "PreconditionFailed 412")))
        XCTAssertTrue(S3ErrorClassifier.isPreconditionFailed(FakeError(description: "PreconditionFailed 412")))
    }

    func testNotFoundAndForbiddenStillWork() {
        XCTAssertTrue(S3ErrorClassifier.isNotFound(FakeError(description: "NotFound")))
        XCTAssertTrue(S3ErrorClassifier.isNotFound(FakeError(description: "status code: 404")))
        XCTAssertTrue(S3ErrorClassifier.isForbidden(FakeError(description: "AccessDenied")))
        XCTAssertFalse(S3ErrorClassifier.isNotFound(FakeError(description: "missingRequiredData")))
    }

    func testNoSuchUpload() {
        // 失効/完了済み UploadId に対する complete/uploadPart が返す NoSuchUpload（Issue #33）。
        let e = FakeError(description: "NoSuchUpload(message: \"The specified multipart upload does not exist.\")")
        XCTAssertTrue(S3ErrorClassifier.isNoSuchUpload(e))
        // NoSuchKey 等の一般 404 を NoSuchUpload と取り違えない。
        XCTAssertFalse(S3ErrorClassifier.isNoSuchUpload(FakeError(description: "NoSuchKey")))
        XCTAssertFalse(S3ErrorClassifier.isNoSuchUpload(FakeError(description: "status code: 404")))
    }
}
