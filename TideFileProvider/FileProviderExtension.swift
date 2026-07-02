import FileProvider
import CryptoKit
import Foundation
import TideCore

/// Tide の File Provider 拡張（M5 Phase 3・読み取り materialize の最小 PoC）。
///
/// - 列挙はマニフェスト（`ManifestSnapshotLoader` → `ManifestTree`）駆動。**DB には一切触らない**
///   （2 プロセス書込競合の構造的回避。単一書き手＝拡張への移行は Phase 6）。
/// - `fetchContents` は `streamObject`（マニフェストの `s3VersionId` に固定）+ サイズ/SHA-256 検証。
/// - 書込系コールバック（create / modify / delete）は**すべて拒否**（read-only PoC）。
/// - item identifier は相対 POSIX パス（マニフェスト・オブジェクトキーと 1:1。ルートは `""`）。
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, @unchecked Sendable {
    private let domain: NSFileProviderDomain
    private let services: ExtensionServices?

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        self.services = ExtensionServices.fromSharedConfig()
        super.init()
        AppLogger.fileProvider.notice("FileProviderExtension initialized (configured: \(self.services != nil))")
    }

    func invalidate() {}

    // MARK: - Items

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        guard let services else {
            completionHandler(nil, NSFileProviderError(.notAuthenticated))
            return progress
        }
        guard let path = identifier.tideRelativePath else {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            return progress
        }
        // completion handler はどのスレッドから呼んでもよい契約なので箱で Task へ運ぶ
        let completion = UncheckedSendableBox(value: completionHandler)
        let task = Task {
            do {
                let tree = try await services.cache.tree()
                guard let node = tree.node(at: path) else {
                    completion.value(nil, NSFileProviderError(.noSuchItem))
                    return
                }
                completion.value(FileProviderItem(node: node), nil)
            } catch {
                AppLogger.fileProvider.error("item(for:) failed: \(String(describing: error), privacy: .private)")
                completion.value(nil, error)
            }
            progress.completedUnitCount = 1
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    // MARK: - Materialize（読み取りの本丸）

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        guard let services else {
            completionHandler(nil, nil, NSFileProviderError(.notAuthenticated))
            return progress
        }
        guard let path = itemIdentifier.tideRelativePath, !path.isEmpty else {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return progress
        }
        let domain = self.domain
        // completion handler はどのスレッドから呼んでもよい契約なので箱で Task へ運ぶ
        let completion = UncheckedSendableBox(value: completionHandler)
        let task = Task {
            do {
                let tree = try await services.cache.tree()
                guard case .file(_, let entry)? = tree.node(at: path) else {
                    completion.value(nil, nil, NSFileProviderError(.noSuchItem))
                    return
                }
                progress.totalUnitCount = max(entry.size, 1)

                // 一時ファイルは system 推奨のドメイン用 tmp（同一ボリューム）へ書く
                let tmpDir = (try? NSFileProviderManager(for: domain)?.temporaryDirectoryURL())
                    ?? FileManager.default.temporaryDirectory
                let tmpURL = tmpDir.appendingPathComponent("fetch-\(UUID().uuidString)")
                FileManager.default.createFile(atPath: tmpURL.path, contents: nil)
                let handle = try FileHandle(forWritingTo: tmpURL)
                defer { try? handle.close() }

                // マニフェストが指す版に固定して取得（enumerate と fetch の間に最新版が
                // 変わっても、提示した itemVersion と中身が食い違わない）
                var hasher = SHA256()
                var written: Int64 = 0
                let result = try await services.s3.streamObject(
                    key: "files/\(path)",
                    versionId: entry.s3VersionId,
                    rangeStart: nil
                ) { chunk in
                    if progress.isCancelled { throw CancellationError() }
                    hasher.update(data: chunk)
                    try handle.write(contentsOf: chunk)
                    written += Int64(chunk.count)
                    progress.completedUnitCount = written
                }
                guard result != nil else {
                    try? FileManager.default.removeItem(at: tmpURL)
                    completion.value(nil, nil, NSFileProviderError(.noSuchItem))
                    return
                }
                try handle.close()

                // commit 前検証（Downloader と同じ不変条件: サイズ一致 + SHA-256 一致）
                let sha = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                guard written == entry.size, sha == entry.sha256 else {
                    try? FileManager.default.removeItem(at: tmpURL)
                    AppLogger.fileProvider.error("fetchContents verification failed for \(path, privacy: .private) (size \(written)/\(entry.size))")
                    completion.value(nil, nil, NSError(
                        domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError,
                        userInfo: [NSLocalizedDescriptionKey: "Downloaded content failed integrity verification."]
                    ))
                    return
                }

                completion.value(tmpURL, FileProviderItem(node: .file(path: path, entry: entry)), nil)
            } catch {
                AppLogger.fileProvider.error("fetchContents failed: \(String(describing: error), privacy: .private)")
                completion.value(nil, nil, error)
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    // MARK: - 書込系（read-only PoC: すべて拒否）

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        completionHandler(nil, [], false, Self.readOnlyError())
        return Progress(totalUnitCount: 1)
    }

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        completionHandler(nil, [], false, Self.readOnlyError())
        return Progress(totalUnitCount: 1)
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        completionHandler(Self.readOnlyError())
        return Progress(totalUnitCount: 1)
    }

    // MARK: - Enumeration

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        guard let services else {
            throw NSFileProviderError(.notAuthenticated)
        }
        if containerItemIdentifier == .workingSet {
            // PoC では working set 追跡をしない（空列挙）
            return FileProviderEnumerator(dirPath: nil, services: services)
        }
        guard let path = containerItemIdentifier.tideRelativePath else {
            throw NSFileProviderError(.noSuchItem)
        }
        return FileProviderEnumerator(dirPath: path, services: services)
    }

    private static func readOnlyError() -> Error {
        NSError(
            domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError,
            userInfo: [NSLocalizedDescriptionKey: "Tide (PoC) is read-only. Edit files in the sync folder instead."]
        )
    }
}

extension NSFileProviderItemIdentifier {
    /// Tide の item identifier（相対 POSIX パス）へのマッピング。ルートは `""`。
    /// working set / trash 等の特殊 identifier は nil。
    var tideRelativePath: String? {
        if self == .rootContainer { return "" }
        if self == .workingSet || self == .trashContainer { return nil }
        return rawValue
    }
}
