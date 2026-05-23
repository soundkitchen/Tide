import Foundation

struct SyncProgress: Equatable, Sendable {
    var totalBytes: Int64 = 0
    var transferredBytes: Int64 = 0
    var currentFile: String?
    var queueDepth: Int = 0
}

enum SyncStatus: Equatable, Sendable {
    case notConfigured
    case idle
    case syncing(SyncProgress)
    case paused
    case error(String)
}
