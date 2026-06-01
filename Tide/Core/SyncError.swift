import Foundation

enum SyncError: Error, CustomStringConvertible {
    case notConfigured(reason: String = "Tide is not configured yet")
    case bucketNotAccessible(reason: String)
    case versioningNotEnabled
    case manifestUpdateFailed(String)
    case fileTooLarge(path: String, size: Int64)
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
