import Foundation

enum SyncError: Error, CustomStringConvertible {
    case notConfigured(reason: String = "Tide is not configured yet")
    case bucketNotAccessible(reason: String)
    case versioningNotEnabled
    case manifestUpdateFailed(String)
    case fileTooLarge(path: String, size: Int64)
    /// 読込中にローカルファイルが変化した（torn read を避けてコミットを見送った）。L6。
    /// リトライ扱いだが give-up カウントには載せず、安定するまで延期する。
    case fileChangedDuringUpload(path: String)
    /// アップロード書込シームで並行更新を検出した（Issue #25 / A）。`remoteEntry` は権威シャードから
    /// 読んだ現リモート版（正規パスへ下ろす版）。give-up カウントに載せず、SyncEngine がローカル編集を
    /// コンフリクトコピーへ退避してから remoteEntry を正規パスへ取得し直す（pull 側と対称）。
    /// `S3ErrorClassifier.isPreconditionFailed/isConditionalConflict` にマッチしない＝RMW リトライに
    /// 飲まれず即伝播する。
    case uploadConflict(path: String, remoteEntry: ManifestFileEntry)
    case awsError(underlying: Error)
    case databaseError(underlying: Error)
    case ioError(underlying: Error)
    case keychain(status: OSStatus)
    case invalidSyncRoot(String)

    var description: String {
        switch self {
        case .notConfigured(let reason):
            return reason
        case .bucketNotAccessible(let reason):
            return "Bucket not accessible: \(reason)"
        case .versioningNotEnabled:
            return "S3 bucket versioning is not enabled"
        case .manifestUpdateFailed(let msg):
            return "Manifest update failed: \(msg)"
        case .fileTooLarge(let path, let size):
            return "File exceeds the per-file upload size limit (\(size) bytes); not backed up. Adjust the limit in Settings: \(path)"
        case .fileChangedDuringUpload(let path):
            return "File changed during upload (torn read avoided); will retry when it settles: \(path)"
        case .uploadConflict(let path, _):
            return "Concurrent update detected on upload; keeping remote and saving local edits as a copy: \(path)"
        case .awsError(let err):
            return "AWS error: \(err)"
        case .databaseError(let err):
            return "Database error: \(err)"
        case .ioError(let err):
            return "I/O error: \(err)"
        case .keychain(let status):
            return "Keychain error (OSStatus \(status))"
        case .invalidSyncRoot(let msg):
            return "Invalid sync root: \(msg)"
        }
    }
}
