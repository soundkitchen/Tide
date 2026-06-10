import Foundation
import GRDB

/// エラーを `SyncIssue` に分類する純粋ロジック（F4 / H2 UI 残の解消）。
/// 判定順序は (1) `SyncError` の case 直マップ →（`awsError` は underlying を剥がして）
/// (2) `S3ErrorClassifier`（S3 固有コード）→ (3) URLError / キーワードでネットワーク →
/// (4) ローカル系の型マッチ → (5) `.other`。全分岐を `SyncIssueClassifierTests` で固定する。
enum SyncIssueClassifier {
    static func classify(error: Error, path: String? = nil, date: Date = Date()) -> SyncIssue {
        SyncIssue(
            id: UUID(),
            date: date,
            path: path,
            category: category(for: error),
            rawDetail: rawDetail(for: error)
        )
    }

    static func category(for error: Error) -> SyncIssue.Category {
        if let sync = error as? SyncError {
            switch sync {
            case .fileTooLarge:
                return .fileTooLarge
            case .fileChangedDuringUpload:
                return .unstableFile
            case .ioError:
                return .localIO
            case .databaseError:
                return .database
            case .notConfigured, .invalidSyncRoot, .versioningNotEnabled,
                 .bucketNotAccessible, .keychain:
                return .configuration
            case .manifestUpdateFailed:
                // 楽観ロック失敗 = 他デバイスとの並行書込。リトライで解消する一時的衝突。
                return .remoteConflict
            case .awsError(let underlying):
                return categoryForGenericError(underlying)
            }
        }
        return categoryForGenericError(error)
    }

    /// SyncError 以外（生 SDK / Foundation / GRDB エラー）の分類。
    private static func categoryForGenericError(_ error: Error) -> SyncIssue.Category {
        // S3 固有コードを先に見る（"connection" 等の汎用語より特異度が高い）。
        if S3ErrorClassifier.isForbidden(error) { return .accessDenied }
        if S3ErrorClassifier.isNotFound(error) { return .notFound }
        if S3ErrorClassifier.isPreconditionFailed(error) || S3ErrorClassifier.isConditionalConflict(error) {
            return .remoteConflict
        }
        if error is URLError { return .network }
        // SDK がエラー型を公開しないため、S3ErrorClassifier と同じ文字列マッチ流儀で補足する。
        let desc = String(describing: error)
        if desc.contains("NSURLError")
            || desc.contains("timed out")
            || desc.contains("network connection")
            || desc.contains("offline")
            || desc.contains("Connection refused")
            || desc.contains("crtError") {
            return .network
        }
        if let cocoa = error as? CocoaError, cocoa.isFileError { return .localIO }
        if error is FileOpenError { return .localIO }
        if error is DatabaseError { return .database }
        return .other
    }

    /// 既定では UI に出さない生詳細。SyncError は `description`（CustomStringConvertible）が
    /// underlying まで含むのでそれを使い、その他は `String(describing:)` 全文。
    private static func rawDetail(for error: Error) -> String {
        if let sync = error as? SyncError { return sync.description }
        return String(describing: error)
    }
}
