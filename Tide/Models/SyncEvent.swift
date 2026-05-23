import Foundation

struct FileChangeEvent: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case createdOrModified
        case deleted
    }
    let relativePath: String   // 同期ルートからの POSIX 相対パス
    let kind: Kind
}
