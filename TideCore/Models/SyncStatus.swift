import Foundation

public struct SyncProgress: Equatable, Sendable {
    public var totalBytes: Int64 = 0
    public var transferredBytes: Int64 = 0
    public var currentFile: String?
    public var queueDepth: Int = 0

    public init(totalBytes: Int64 = 0, transferredBytes: Int64 = 0, currentFile: String? = nil, queueDepth: Int = 0) {
        self.totalBytes = totalBytes
        self.transferredBytes = transferredBytes
        self.currentFile = currentFile
        self.queueDepth = queueDepth
    }
}

public enum SyncStatus: Equatable, Sendable {
    case notConfigured
    case idle
    case syncing(SyncProgress)
    case paused
    case error(String)
}
