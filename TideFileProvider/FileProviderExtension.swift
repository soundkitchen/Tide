import FileProvider
import CryptoKit
import Foundation
import TideCore

/// Tide の File Provider 拡張（M5 Phase 3・読み取り materialize の最小 PoC）。
///
/// - 列挙はマニフェスト（`ManifestSnapshotLoader` → `ManifestTree`）駆動。**DB には一切触らない**
///   （2 プロセス書込競合の構造的回避。Phase 5 は「拡張 = 第 3 のデバイス」方式＝DB 非接触のまま
///   S3 へ直接書く。旧「単一書き手＝拡張」構想は撤回）。
/// - `fetchContents` は `streamObject`（マニフェストの `s3VersionId` に固定）+ サイズ/SHA-256 検証。
/// - 書込系コールバック（create / modify / delete）は**すべて拒否**（read-only PoC）。
/// - item identifier は **kind 織り込み形式**: `f:`（ファイル）/ `d:`（ディレクトリ）+ 相対 POSIX
///   パス（マニフェスト・オブジェクトキーと 1:1。ルートは `.rootContainer`。M5 Phase 5-1 で
///   `p:` から変更 — 詳細はファイル末尾の extension 参照）。プレフィックスは予約 identifier
///   （`.rootContainer` 等の rawValue）と同名のファイルパスが衝突して階層が破綻するのを
///   構造的に防ぐ役割も引き続き担う（PR #50 レビュー #4）。
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
        guard let ref = identifier.tidePathAndKind else {
            progress.completedUnitCount = 1
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            return progress
        }
        let path = ref.path
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
                // kind 不一致（id は f: なのに tree ではディレクトリ等）は「その kind の item は
                // もう無い」= noSuchItem（kind 変化後の stale 旧 id が必ず通る正常系なので notice。
                // path 自体はツリーに実在するため「not in manifest tree」ログとは分ける —
                // 共用すると shard に entry が在るのに無いと出る誤診誘導になる。PR #57 レビュー #3）。
                guard node.isDirectory == ref.isDirectory else {
                    AppLogger.fileProvider.notice("item(for:): kind mismatch (stale id, noSuchItem): \(path, privacy: .private)")
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
        guard let ref = itemIdentifier.tidePathAndKind, !ref.path.isEmpty, !ref.isDirectory else {
            progress.completedUnitCount = 1
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return progress
        }
        let path = ref.path
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
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                String(localized: "Downloaded content failed integrity verification.")
                        ]
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
        // 新規作成は Phase 5-3 で対応（root 孤児 UX の解消もそこで）。
        completionHandler(nil, [], false, Self.createUnsupportedError())
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
        let progress = Progress(totalUnitCount: 1)
        guard let services else {
            progress.completedUnitCount = 1
            completionHandler(nil, [], false, NSFileProviderError(.notAuthenticated))
            return progress
        }
        guard let ref = item.itemIdentifier.tidePathAndKind, !ref.path.isEmpty else {
            progress.completedUnitCount = 1
            completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
            return progress
        }
        guard !ref.isDirectory else {
            // ディレクトリのメタデータ変更・削除は Phase 5-3 で対応。
            progress.completedUnitCount = 1
            completionHandler(nil, [], false, Self.folderChangesUnsupportedError())
            return progress
        }
        guard !changedFields.contains(.filename), !changedFields.contains(.parentItemIdentifier) else {
            // 改名 / 移動は Phase 5-4（capability 未許可なので通常は来ない防御）。
            progress.completedUnitCount = 1
            completionHandler(nil, [], false, Self.renameUnsupportedError())
            return progress
        }
        let path = ref.path
        let completion = UncheckedSendableBox(value: completionHandler)

        guard changedFields.contains(.contents) else {
            // メタデータのみ（mtime / タグ等）: マニフェストに保存先が無いので**黙って受理**する
            // （remainingFields に残すと fileproviderd が永久再試行する）。権威 = 現ツリーの
            // entry から item を返す。
            let task = Task {
                defer { progress.completedUnitCount = progress.totalUnitCount }
                do {
                    let tree = try await services.cache.current().tree
                    guard let node = tree.node(at: path), !node.isDirectory else {
                        completion.value(nil, [], false, NSFileProviderError(.noSuchItem))
                        return
                    }
                    completion.value(FileProviderItem(node: node), [], false, nil)
                } catch {
                    completion.value(nil, [], false, error)
                }
            }
            progress.cancellationHandler = { task.cancel() }
            return progress
        }

        guard let newContents else {
            progress.completedUnitCount = 1
            completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
            return progress
        }
        // 3-way ベース = システムが最後に見た itemVersion（= 旧 sha256）。DB 非接触のまま
        // 競合検出できる（「拡張 = 第 3 のデバイス」の要・docs/08）。
        let baseSha = FileProviderWritePolicy.baseSha(fromContentVersion: version.contentVersion)
        let contentModified = item.contentModificationDate ?? nil
        let boxedURL = UncheckedSendableBox(value: newContents)
        let task = Task {
            defer { progress.completedUnitCount = progress.totalUnitCount }
            do {
                let outcome = try await services.writer.modifyFileContents(
                    path: path, contentsURL: boxedURL.value,
                    baseSha: baseSha, contentModified: contentModified
                )
                switch outcome {
                case .written(let entry):
                    // 返却 item は必ずシャードへ書いた entry から生成（自世代 append と同一
                    // itemVersion = 直後の enumerateChanges が no-op・bounce しない）。
                    completion.value(FileProviderItem(node: .file(path: path, entry: entry)), [], false, nil)
                case .conflict(let remote, let copyPath, _):
                    // 正規パスはリモート版が勝つ（FSEvents 側と対称）。shouldFetchContent=true で
                    // システムにリモート内容を取り直させる。ローカル編集は conflict copy として
                    // 自世代に反映済み → 直後の enumerateChanges で新 item として出現する。
                    AppLogger.fileProvider.notice("modifyItem: upload conflict — local edit preserved as copy: \(copyPath, privacy: .private)")
                    completion.value(FileProviderItem(node: .file(path: path, entry: remote)), [], true, nil)
                }
            } catch {
                AppLogger.fileProvider.error("modifyItem failed: \(String(describing: error), privacy: .private)")
                completion.value(nil, [], false, error)
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        guard let services else {
            progress.completedUnitCount = 1
            completionHandler(NSFileProviderError(.notAuthenticated))
            return progress
        }
        guard let ref = identifier.tidePathAndKind, !ref.path.isEmpty else {
            // 未知 id の削除要求 = 対象はもう無い（noSuchItem でシステム側の掃除に任せる）。
            progress.completedUnitCount = 1
            completionHandler(NSFileProviderError(.noSuchItem))
            return progress
        }
        guard !ref.isDirectory else {
            // ディレクトリ削除（再帰）は Phase 5-3 で対応。
            progress.completedUnitCount = 1
            completionHandler(Self.folderChangesUnsupportedError())
            return progress
        }
        let baseSha = FileProviderWritePolicy.baseSha(fromContentVersion: version.contentVersion)
        let completion = UncheckedSendableBox(value: completionHandler)
        let task = Task {
            defer { progress.completedUnitCount = progress.totalUnitCount }
            do {
                switch try await services.writer.deleteFile(path: ref.path, baseSha: baseSha) {
                case .removed, .alreadyGone:
                    completion.value(nil)
                case .rejected(let remote):
                    // リモートがベースより進んでいた → 削除拒否 + 最新 item を添える
                    // （システムが最新版を復元する。「データ損失 < 重複」）。
                    AppLogger.fileProvider.notice("deleteItem: rejected (remote changed since base): \(ref.path, privacy: .private)")
                    completion.value(NSError.fileProviderErrorForRejectedDeletion(
                        of: FileProviderItem(node: .file(path: ref.path, entry: remote))
                    ))
                }
            } catch {
                AppLogger.fileProvider.error("deleteItem failed: \(String(describing: error), privacy: .private)")
                completion.value(error)
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
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
        guard let ref = containerItemIdentifier.tidePathAndKind, ref.isDirectory else {
            throw NSFileProviderError(.noSuchItem)
        }
        return FileProviderEnumerator(dirPath: ref.path, services: services)
    }

    private static func createUnsupportedError() -> Error {
        NSError(
            domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError,
            userInfo: [
                NSLocalizedDescriptionKey:
                    String(localized: "Creating new items in Tide is not supported yet. Add files in the sync folder instead.")
            ]
        )
    }

    private static func folderChangesUnsupportedError() -> Error {
        NSError(
            domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError,
            userInfo: [
                NSLocalizedDescriptionKey:
                    String(localized: "Folder changes in Tide are not supported yet.")
            ]
        )
    }

    private static func renameUnsupportedError() -> Error {
        NSError(
            domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError,
            userInfo: [
                NSLocalizedDescriptionKey:
                    String(localized: "Renaming or moving items in Tide is not supported yet.")
            ]
        )
    }
}

extension NSFileProviderItemIdentifier {
    /// Tide の item identifier のプレフィックス（M5 Phase 5-1 で kind 織り込み形式へ変更）:
    /// ファイル = `f:<相対 POSIX パス>` / ディレクトリ = `d:<相対 POSIX パス>`。ルートは
    /// `.rootContainer`。予約 identifier（rootContainer 等の rawValue）と同名ファイルとの
    /// 衝突回避（旧 `p:` の目的）も引き続きプレフィックスが担う。
    ///
    /// kind を id に織り込む理由: fileproviderd は同一 id の kind（file⇄dir）変化を受理しない —
    /// 単一レスポンス内の delete+update も、moreComing ページ分割も、自己 signal による
    /// 別セッション（22ms 差）でも「item changed」の ingest バッチに合成され delete が update を
    /// 打ち消す（item 消失。2026-07-05〜06 実機確定）。kind ごとに別 id なら kind 変化 =
    /// 「旧 id の削除 + 新 id の出現」となり、同一 id 合成の余地が構造的に消える。
    /// **旧 `p:` 形式の有効化済みドメインは Disable → Enable で作り直す**（docs/09 の
    /// 「identifier スキーマを変えたら作り直し」どおり。実験的 opt-in 機能のため移行コードは
    /// 持たない — 旧 id は `tidePathAndKind == nil` → noSuchItem に落ちる）。
    static let tideFilePrefix = "f:"
    static let tideDirectoryPrefix = "d:"

    /// Tide の item identifier → (相対 POSIX パス, ディレクトリか)。ルートは `("", true)`。
    /// working set / trash / 旧 `p:` / 未知の identifier は nil。
    /// 裸の `"f:"` / `"d:"`（空パス）も nil = 不正 id（root の正規表現は `.rootContainer` のみ。
    /// 受理すると root 高速パス等が「要求 id と食い違う item」を成功応答しうる。自前の mint 経路は
    /// この形を作らないが、書込対応でデーモン供給 id を受ける面が増える前の防御。PR #57 レビュー #5）。
    var tidePathAndKind: (path: String, isDirectory: Bool)? {
        if self == .rootContainer { return ("", true) }
        if rawValue.hasPrefix(Self.tideFilePrefix) {
            let path = String(rawValue.dropFirst(Self.tideFilePrefix.count))
            return path.isEmpty ? nil : (path, false)
        }
        if rawValue.hasPrefix(Self.tideDirectoryPrefix) {
            let path = String(rawValue.dropFirst(Self.tideDirectoryPrefix.count))
            return path.isEmpty ? nil : (path, true)
        }
        return nil
    }

    /// 相対 POSIX パス + kind → Tide の item identifier。ルート（`""`）は `.rootContainer`。
    init(tideRelativePath path: String, isDirectory: Bool) {
        if path.isEmpty {
            self = .rootContainer
        } else {
            let prefix = isDirectory ? Self.tideDirectoryPrefix : Self.tideFilePrefix
            self = NSFileProviderItemIdentifier(prefix + path)
        }
    }

    /// ノード → item identifier（kind はノードから取る）。
    init(tideNode node: ManifestTree.Node) {
        self.init(tideRelativePath: node.path, isDirectory: node.isDirectory)
    }
}
