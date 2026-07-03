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
/// - item identifier は `p:` + 相対 POSIX パス（マニフェスト・オブジェクトキーと 1:1。ルートは
///   `.rootContainer`）。プレフィックスは予約 identifier（`.rootContainer` 等の rawValue）と
///   同名のファイルパスが衝突して階層が破綻するのを構造的に防ぐ（PR #50 レビュー #4）。
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, @unchecked Sendable {
    private let domain: NSFileProviderDomain
    private let services: ExtensionServices?

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        self.services = ExtensionServices.fromSharedConfig(domain: domain)
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
            progress.completedUnitCount = 1
            completionHandler(nil, NSFileProviderError(.notAuthenticated))
            return progress
        }
        guard let path = identifier.tideRelativePath else {
            progress.completedUnitCount = 1
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            return progress
        }
        // root は定数（合成ディレクトリ）なのでマニフェストロードを経由しない —
        // ドメインアタッチ時の余計な S3 往復と「一過性エラーで root が失敗アイテム化」を避ける。
        // mtime は常に nil（ManifestTree 側も root には畳み込まない＝itemVersion が経路で揺れない）。
        if path.isEmpty {
            progress.completedUnitCount = 1
            completionHandler(FileProviderItem(node: .directory(path: "", mtime: nil)), nil)
            return progress
        }
        // completion handler はどのスレッドから呼んでもよい契約なので箱で Task へ運ぶ
        let completion = UncheckedSendableBox(value: completionHandler)
        let task = Task {
            defer { progress.completedUnitCount = progress.totalUnitCount }
            do {
                let tree = try await services.cache.current().tree
                guard let node = tree.node(at: path) else {
                    AppLogger.fileProvider.error("item(for:): path not in manifest tree (noSuchItem): \(path, privacy: .private)")
                    completion.value(nil, NSFileProviderError(.noSuchItem))
                    return
                }
                completion.value(FileProviderItem(node: node), nil)
            } catch {
                AppLogger.fileProvider.error("item(for:) failed: \(String(describing: error), privacy: .private)")
                completion.value(nil, error)
            }
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
            progress.completedUnitCount = 1
            completionHandler(nil, nil, NSFileProviderError(.notAuthenticated))
            return progress
        }
        guard let path = itemIdentifier.tideRelativePath, !path.isEmpty else {
            progress.completedUnitCount = 1
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return progress
        }
        let domain = self.domain
        // completion handler はどのスレッドから呼んでもよい契約なので箱で Task へ運ぶ
        let completion = UncheckedSendableBox(value: completionHandler)
        let task = Task {
            // どの経路（中間 guard / 成功 / catch）でも Progress を完了させる（PR #50 再レビュー #1）
            defer { progress.completedUnitCount = progress.totalUnitCount }
            // 失敗経路（ガード / throw / キャンセル）の部分書き込み tmp をここで一元的に掃除する。
            // 成功時は cleanupURL を nil に戻してからシステムに tmp を引き渡す（PR #50 レビュー #2）。
            var cleanupURL: URL?
            defer { if let cleanupURL { try? FileManager.default.removeItem(at: cleanupURL) } }
            do {
                let tree = try await services.cache.current().tree
                guard case .file(_, let entry)? = tree.node(at: path) else {
                    // noSuchItem を返すとデーモンはプレースホルダごと item を削除する（実機確認）。
                    // 本当に「無い」時以外に返さないこと。診断のため必ずログを残す。
                    AppLogger.fileProvider.error("fetchContents: path not in manifest tree (noSuchItem): \(path, privacy: .private)")
                    completion.value(nil, nil, NSFileProviderError(.noSuchItem))
                    return
                }
                progress.totalUnitCount = max(entry.size, 1)

                // 一時ファイルは system 推奨のドメイン用 tmp（同一ボリューム）へ書く
                let tmpDir = (try? NSFileProviderManager(for: domain)?.temporaryDirectoryURL())
                    ?? FileManager.default.temporaryDirectory
                let tmpURL = tmpDir.appendingPathComponent("fetch-\(UUID().uuidString)")
                FileManager.default.createFile(atPath: tmpURL.path, contents: nil)
                cleanupURL = tmpURL
                let handle = try FileHandle(forWritingTo: tmpURL)
                defer { try? handle.close() }

                // 1 回ぶんのストリーミング取得（tmp 先頭から書き直し）。404 系は nil。
                let s3 = services.s3
                func download(_ versionId: String?) async throws -> (sha: String, written: Int64)? {
                    try handle.truncate(atOffset: 0)
                    var hasher = SHA256()
                    var written: Int64 = 0
                    progress.completedUnitCount = 0
                    let result = try await s3.streamObject(
                        key: "files/\(path)", versionId: versionId, rangeStart: nil
                    ) { chunk in
                        if progress.isCancelled { throw CancellationError() }
                        hasher.update(data: chunk)
                        try handle.write(contentsOf: chunk)
                        written += Int64(chunk.count)
                        progress.completedUnitCount = written
                    }
                    guard result != nil else { return nil }
                    return (HashCalculator.hex(hasher.finalize()), written)
                }

                // マニフェストが指す版を第一候補で取得（enumerate と fetch の間に最新版が
                // 変わっても、提示した itemVersion と中身が食い違わない）。その版が消えている
                // 場合（ライフサイクルの旧版失効・stale な manifest versionId）は最新版へ
                // フォールバックする — 内容の同一性は下の SHA-256 ゲートが保証する。
                var outcome = try await download(entry.s3VersionId)
                if outcome == nil, entry.s3VersionId != nil {
                    AppLogger.fileProvider.notice("fetchContents: pinned version missing; falling back to latest: \(path, privacy: .private)")
                    outcome = try await download(nil)
                }
                guard let (sha, written) = outcome else {
                    // 最新版も無い＝本当に消えている時だけ noSuchItem（デーモンが item を削除する）
                    AppLogger.fileProvider.error("fetchContents: object not found on S3 (noSuchItem): \(path, privacy: .private)")
                    completion.value(nil, nil, NSFileProviderError(.noSuchItem))
                    return
                }
                try handle.close()

                // commit 前検証（Downloader と同じ不変条件: サイズ一致 + SHA-256 一致）。
                // 不一致は noSuchItem では**なく** I/O エラー（item を消させず後で再試行可能に）。
                guard written == entry.size, sha == entry.sha256 else {
                    AppLogger.fileProvider.error("fetchContents verification failed for \(path, privacy: .private) (size \(written)/\(entry.size))")
                    completion.value(nil, nil, NSError(
                        domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError,
                        userInfo: [NSLocalizedDescriptionKey: "Downloaded content failed integrity verification."]
                    ))
                    return
                }

                // 成功: tmp はシステムが引き取るので掃除対象から外す（Progress 完了は Task 冒頭の defer）
                cleanupURL = nil
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
            // macOS の replicated 拡張ではリモート変更がシステムに届く唯一の経路が
            // working set の enumerateChanges（個別コンテナへの signal は無視される）。
            // FruitBasket 同様、working set = ドメイン全 item として列挙する（Phase 4）。
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
    /// Tide の item identifier のパスプレフィックス。予約 identifier
    /// （`NSFileProviderRootContainerItemIdentifier` 等の rawValue）と同名のファイルが
    /// マニフェストに居ても衝突しないよう、パス由来の identifier は必ずこれを付ける。
    static let tidePathPrefix = "p:"

    /// Tide の item identifier → 相対 POSIX パス。ルートは `""`。
    /// working set / trash / 未知の identifier（プレフィックス無し）は nil。
    var tideRelativePath: String? {
        if self == .rootContainer { return "" }
        guard rawValue.hasPrefix(Self.tidePathPrefix) else { return nil }
        return String(rawValue.dropFirst(Self.tidePathPrefix.count))
    }

    /// 相対 POSIX パス → Tide の item identifier。ルート（`""`）は `.rootContainer`。
    init(tideRelativePath path: String) {
        self = path.isEmpty
            ? .rootContainer
            : NSFileProviderItemIdentifier(Self.tidePathPrefix + path)
    }
}
