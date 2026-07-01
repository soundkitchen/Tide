import Foundation

public struct FileChangeEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case createdOrModified
        case deleted
    }
    public let relativePath: String   // 同期ルートからの POSIX 相対パス
    public let kind: Kind

    public init(relativePath: String, kind: Kind) {
        self.relativePath = relativePath
        self.kind = kind
    }
}
