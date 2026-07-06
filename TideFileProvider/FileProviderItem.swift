import FileProvider
import Foundation
import TideCore
import UniformTypeIdentifiers

/// `ManifestTree.Node` を `NSFileProviderItem` に写像する読み取り専用アイテム（M5 Phase 3）。
/// identifier = kind プレフィックス + 相対 POSIX パス（`f:`/`d:`・ルートは `.rootContainer`。
/// M5 Phase 5-1 で kind 織り込み形式へ変更）。バージョンは sha256 をそのまま使う。
final class FileProviderItem: NSObject, NSFileProviderItem, @unchecked Sendable {
    private let node: ManifestTree.Node

    init(node: ManifestTree.Node) {
        self.node = node
    }

    var itemIdentifier: NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier(tideNode: node)
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        let components = node.path.split(separator: "/")
        guard components.count > 1 else { return .rootContainer }
        // 親は常に合成ディレクトリ
        return NSFileProviderItemIdentifier(
            tideRelativePath: components.dropLast().joined(separator: "/"), isDirectory: true)
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
            // dir の削除・配下追加は Phase 5-3、改名/移動は Phase 5-4 で解放する。
            return [.allowsReading, .allowsContentEnumerating]
        case .file:
            // M5 Phase 5-2: 内容編集と削除を解放（改名/移動 = .allowsRenaming/.allowsReparenting
            // は Phase 5-4。未許可なので Finder 上はグレーアウトされる）。
            return [.allowsReading, .allowsWriting, .allowsDeleting]
        }
    }

    var itemVersion: NSFileProviderItemVersion {
        // contentVersion の符号化は TideCore の `FileProviderWritePolicy` に集約（`baseSha` の対・
        // 書込経路の 3-way ベース抽出と往復整合を保証。PR #58 レビュー #8）。
        let content = FileProviderWritePolicy.contentVersion(for: node)
        switch node {
        case .directory(_, let mtime):
            // ディレクトリは合成物（コンテンツは持たない）。配下の最大 mtime（合成値）を
            // metadataVersion に載せ、配下更新でメタデータ（表示日付）が追従するようにする。
            let meta = mtime.map { "dir-\(ISO8601.format($0))" } ?? "dir"
            return NSFileProviderItemVersion(contentVersion: content, metadataVersion: Data(meta.utf8))
        case .file:
            // file は content == metadata（sha256）— 内容変化がメタ変化でもある。
            return NSFileProviderItemVersion(contentVersion: content, metadataVersion: content)
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
