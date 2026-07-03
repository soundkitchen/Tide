import FileProvider
import Foundation
import TideCore
import UniformTypeIdentifiers

/// `ManifestTree.Node` を `NSFileProviderItem` に写像する読み取り専用アイテム（M5 Phase 3）。
/// identifier = 相対 POSIX パス（ルートは `.rootContainer`）。バージョンは sha256 をそのまま使う。
final class FileProviderItem: NSObject, NSFileProviderItem, @unchecked Sendable {
    private let node: ManifestTree.Node

    init(node: ManifestTree.Node) {
        self.node = node
    }

    var itemIdentifier: NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier(tideRelativePath: node.path)
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        let components = node.path.split(separator: "/")
        guard components.count > 1 else { return .rootContainer }
        return NSFileProviderItemIdentifier(
            tideRelativePath: components.dropLast().joined(separator: "/"))
    }

    var filename: String {
        node.path.isEmpty ? "Tide" : node.name
    }

    var contentType: UTType {
        switch node {
        case .directory:
            return .folder
        case .file(let path, _):
            let ext = (path as NSString).pathExtension
            return ext.isEmpty ? .data : (UTType(filenameExtension: ext) ?? .data)
        }
    }

    var capabilities: NSFileProviderItemCapabilities {
        switch node {
        case .directory:
            return [.allowsReading, .allowsContentEnumerating]
        case .file:
            return [.allowsReading]
        }
    }

    var itemVersion: NSFileProviderItemVersion {
        switch node {
        case .directory:
            // ディレクトリは合成物で固有バージョンを持たない
            return NSFileProviderItemVersion(
                contentVersion: Data("dir".utf8), metadataVersion: Data("dir".utf8))
        case .file(_, let entry):
            let v = Data(entry.sha256.utf8)
            return NSFileProviderItemVersion(contentVersion: v, metadataVersion: v)
        }
    }

    var documentSize: NSNumber? {
        if case .file(_, let entry) = node { return NSNumber(value: entry.size) }
        return nil
    }

    var contentModificationDate: Date? {
        if case .file(_, let entry) = node { return ISO8601.parse(entry.mtime) }
        return nil
    }

    var contentPolicy: NSFileProviderContentPolicy {
        // dataless PoC の本旨: 実体はダウンロードせずプレースホルダのまま（開いた時に fetch）
        .downloadLazily
    }
}
