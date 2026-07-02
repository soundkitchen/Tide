import FileProvider
import Foundation
import TideCore

/// マニフェストツリー駆動の列挙（M5 Phase 3・読み取り専用）。
/// `dirPath == nil` は working set 用の空列挙。
final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    private let dirPath: String?
    private let services: ExtensionServices

    init(dirPath: String?, services: ExtensionServices) {
        self.dirPath = dirPath
        self.services = services
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        guard let dirPath else {
            // working set: 追跡なし（Phase 4 で enumerateChanges と一緒に実装）
            observer.finishEnumerating(upTo: nil)
            return
        }
        let services = self.services
        // observer はどのスレッドから呼んでもよい契約（システム側で直列化される）なので、
        // 非 Sendable なまま Task へ箱で運ぶ。
        let boxed = UncheckedSendableBox(value: observer)
        Task {
            do {
                let tree = try await services.cache.tree()
                guard let children = tree.children(of: dirPath) else {
                    boxed.value.finishEnumeratingWithError(NSFileProviderError(.noSuchItem))
                    return
                }
                if !children.isEmpty {
                    boxed.value.didEnumerate(children.map(FileProviderItem.init(node:)))
                }
                boxed.value.finishEnumerating(upTo: nil)
            } catch {
                AppLogger.fileProvider.error("enumerateItems failed: \(String(describing: error), privacy: .private)")
                boxed.value.finishEnumeratingWithError(error)
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        // PoC では変更追跡をしない（増分列挙 + signalEnumerator は Phase 4）。
        // 「変更なし」で同じ anchor を返す＝表示済み内容が維持される。
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Data("tide-poc-static".utf8)))
    }
}
