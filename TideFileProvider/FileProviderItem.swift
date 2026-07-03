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
        case .directory(_, let mtime):
            // ディレクトリは合成物（コンテンツは持たない）。配下の最大 mtime（合成値）を
            // metadataVersion に載せ、配下更新でメタデータ（表示日付）が追従するようにする。
            let meta = mtime.map { "dir-\(ISO8601.format($0))" } ?? "dir"
            return NSFileProviderItemVersion(
                contentVersion: Data("dir".utf8), metadataVersion: Data(meta.utf8))
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
        switch node {
        case .file(_, let entry):
            return ISO8601.parse(entry.mtime)
        case .directory(_, let mtime):
            // 合成 mtime（配下ファイルの最大値）。無指定 nil のままだと Finder が 1970 を
            // 表示する（Phase 3 PoC の既知の癖）。
            return mtime
        }
    }

    var contentPolicy: NSFileProviderContentPolicy {
        // dataless PoC の本旨: 実体はダウンロードせずプレースホルダのまま（開いた時に fetch）
        .downloadLazily
    }
}
