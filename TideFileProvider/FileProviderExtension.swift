import FileProvider
import CryptoKit
import Foundation
import TideCore
import UniformTypeIdentifiers

/// Tide の File Provider 拡張（M5 Phase 3 読み取り materialize → Phase 5 双方向書込）。
///
/// - 列挙はマニフェスト（`ManifestSnapshotLoader` → `ManifestTree`）駆動。**DB には一切触らない**
///   （2 プロセス書込競合の構造的回避。Phase 5 は「拡張 = 第 3 のデバイス」方式＝DB 非接触のまま
///   S3 へ直接書く。旧「単一書き手＝拡張」構想は撤回）。
/// - `fetchContents` は `streamObject`（マニフェストの `s3VersionId` に固定）+ サイズ/SHA-256 検証。
/// - 書込系コールバック: modifyItem（.contents）+ deleteItem（file）= Phase 5-2、
///   createItem（file/folder）+ deleteItem（dir 再帰）+ dir メタデータ modify = Phase 5-3。
///   改名/移動（.filename / .parentItemIdentifier）のみ Phase 5-4 で対応予定。
///   除外（機密網 / `.syncignore` / symlink / 検証不能名）は `ExcludedFromSync` = ローカル温存。
/// - item identifier は **kind 織り込み形式**: `f:`（ファイル）/ `d:`（ディレクトリ）+ 相対 POSIX
///   パス（マニフェスト・オブジェクトキーと 1:1。ルートは `.rootContainer`。M5 Phase 5-1 で
///   `p:` から変更 — 詳細はファイル末尾の extension 参照）。プレフィックスは予約 identifier
///   （`.rootContainer` 等の rawValue）と同名のファイルパスが衝突して階層が破綻するのを
///   構造的に防ぐ役割も引き続き担う（PR #50 レビュー #4）。`d:` の path 決定的 id により、
///   ローカル仮想フォルダ（空フォルダ受理）とマニフェスト実体化後の合成 dir が同一 item に収束する。
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
                    if ref.isDirectory {
                        // マニフェスト外の dir id = ローカル作成の仮想フォルダ（M5 Phase 5-3 の
                        // 空フォルダ仮想受理）。noSuchItem を返すとデーモンがローカルフォルダごと
                        // 掃除してしまうため、合成 dir を返して温存する。リモート削除の伝播は
                        // enumerateChanges の didDeleteItems が権威なので、消えた dir がここで
                        // resurrect することはない。
                        completion.value(FileProviderItem(node: .directory(path: path, mtime: nil)), nil)
                        return
                    }
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

    // MARK: - 書込系（M5 Phase 5-2/5-3: 改名/移動 = 5-4 のみ未対応）

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        guard let services else {
            progress.completedUnitCount = 1
            completionHandler(nil, [], false, NSFileProviderError(.notAuthenticated))
            return progress
        }
        // 親は Tide の dir id（root 含む）のみ（trash 等は未対応・capabilities 未許可の防御）。
        guard let parent = itemTemplate.parentItemIdentifier.tidePathAndKind, parent.isDirectory else {
            progress.completedUnitCount = 1
            completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
            return progress
        }
        // パス合成: filename 起因の構造破壊は childPath が nil、フルパス網羅検証（バックスラッシュ
        // 等）は validateRelativePath。同期できない名前は ExcludedFromSync でローカル温存
        //（FSEvents モードが検証不能パスを同期対象にしないのと同じ側・S3 は非汚染）。
        guard
            let path = FileProviderWritePolicy.childPath(
                parentPath: parent.path, filename: itemTemplate.filename),
            (try? PathValidator.validateRelativePath(path)) != nil
        else {
            AppLogger.fileProvider.notice("createItem: unsyncable name (excludedFromSync): \(itemTemplate.filename, privacy: .private)")
            progress.completedUnitCount = 1
            completionHandler(nil, [], false, NSFileProviderError(.excludedFromSync))
            return progress
        }
        let contentType = itemTemplate.contentType
        // symlink は絶対に同期しない（セキュリティゲート）— ローカルに残して同期対象外。
        if contentType?.conforms(to: .symbolicLink) == true {
            AppLogger.fileProvider.notice("createItem: symlink excluded from sync: \(path, privacy: .private)")
            progress.completedUnitCount = 1
            completionHandler(nil, [], false, NSFileProviderError(.excludedFromSync))
            return progress
        }

        if contentType?.conforms(to: .directory) == true {
            // 機密網ディレクトリ（.aws / .ssh 等）は subtree ごとローカル温存。単発の
            // ExcludedFromSync で配下の個別 createItem 評価も生じない（FSEvents スキャンの
            // 機密網 dir skipDescendants と対称）。ユーザ `.syncignore` の dir 単位除外は
            // **意図的にしない** — `!` 再包含（同層否定）の再現は per-file 評価が担う
            //（スキャン側も dir prune はしない）。
            if HardcodedIgnoreRules.shouldIgnore(relativePath: path) {
                AppLogger.fileProvider.notice("createItem: hardcoded-ignored directory excluded: \(path, privacy: .private)")
                progress.completedUnitCount = 1
                completionHandler(nil, [], false, NSFileProviderError(.excludedFromSync))
                return progress
            }
            // 空フォルダのローカル仮想受理（S3 非接触・2026-07-09 ユーザ確定）: マニフェストに
            // ディレクトリエントリは無く、配下にファイルが入った時点で合成 dir として実体化・
            // 同期される。空のままなら他デバイスへ伝播しない（FSEvents モードの「空ディレクトリは
            // 同期しない」と同じ）。id は path 決定的（`d:<path>`）なので、実体化後の合成 dir と
            // 同一 item に収束する。
            progress.completedUnitCount = 1
            completionHandler(
                FileProviderItem(
                    node: .directory(path: path, mtime: itemTemplate.contentModificationDate ?? nil)),
                [], false, nil
            )
            return progress
        }

        let completion = UncheckedSendableBox(value: completionHandler)
        let boxedURL = UncheckedSendableBox(value: url)
        let contentModified = itemTemplate.contentModificationDate ?? nil
        let mayAlreadyExist = options.contains(.mayAlreadyExist)
        let task = Task {
            defer { progress.completedUnitCount = progress.totalUnitCount }
            do {
                let current = try await services.cache.current()
                // kind 衝突（同 path にディレクトリが実在）→ FilenameCollision: システムが
                // 片方をリネーム（バウンス）して createItem を再試行する（SDK 契約）。
                // ※ このチェックはキャッシュ済みツリー基準 — RMW はファイル entry しか見ない
                // （dir は合成物でシャード横断のため）ので、直後にリモートで dir が生える狭い
                // レースは塞げない（既知の記録レースと同クラス・ManifestTree は directory-wins で
                // 破綻しない）。
                if let node = current.tree.node(at: path), node.isDirectory {
                    completion.value(nil, [], false, NSFileProviderError(.filenameCollision))
                    return
                }
                // 除外判定は FSEvents モードと同一関数・同一優先順位（IgnoreDecision.shouldSkip =
                // 機密網 → `.syncignore` 自身の保護 → ユーザ層状パターンは未追跡のみ）。
                // ExcludedFromSync = ローカルに残して同期しない + メタデータ変化時に再評価が来る。
                let isTracked = current.tree.node(at: path) != nil
                let layered = try await services.ignore.layeredIgnore(
                    tree: current.tree, anchor: current.anchor)
                if IgnoreDecision.shouldSkip(
                    relativePath: path, isAlreadyTracked: isTracked, matcher: layered) {
                    AppLogger.fileProvider.notice("createItem: excluded from sync: \(path, privacy: .private)")
                    completion.value(nil, [], false, NSFileProviderError(.excludedFromSync))
                    return
                }
                // 再取り込み（mayAlreadyExist）で内容が無い = dataless 再発見: マニフェストと
                // 突合して既存 item に束ねる。突合できなければ nil 返し = システムが on-disk の
                // dataless プレースホルダを掃除する（SDK 契約・実体データは失われない）。
                guard let contentsURL = boxedURL.value else {
                    if mayAlreadyExist {
                        if let node = current.tree.node(at: path), !node.isDirectory {
                            completion.value(FileProviderItem(node: node), [], false, nil)
                        } else {
                            completion.value(nil, [], false, nil)
                        }
                        return
                    }
                    // 内容なしの新規作成 = 空ファイルとしてアップロード
                    let outcome = try await services.writer.modifyFileContents(
                        path: path, contentsURL: nil, baseSha: nil, contentModified: contentModified
                    )
                    Self.completeCreate(outcome, path: path, completion: completion)
                    return
                }
                // 新規作成 = base nil の書込。`decideUpload(base: nil)` が「リモート不在 = 作成 /
                // 同一 sha = 冪等（mayAlreadyExist の再取り込みもここで合流）/ 別内容 = 競合」を
                // 裁く。DeletionConflicted（working set 削除 vs ローカル編集）も同経路 —
                // マニフェスト不在なら編集内容で再作成（keepLocalRemoteDeleted と同じ側）。
                let outcome = try await services.writer.modifyFileContents(
                    path: path, contentsURL: contentsURL, baseSha: nil,
                    contentModified: contentModified
                )
                Self.completeCreate(outcome, path: path, completion: completion)
            } catch {
                AppLogger.fileProvider.error("createItem failed: \(String(describing: error), privacy: .private)")
                completion.value(nil, [], false, error)
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    /// createItem の書込結果 → completion 変換（内容あり/なしの 2 経路で共用）。
    private static func completeCreate(
        _ outcome: ExtensionWriter.ModifyOutcome,
        path: String,
        completion: UncheckedSendableBox<(NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void>
    ) {
        switch outcome {
        case .written(let entry):
            completion.value(FileProviderItem(node: .file(path: path, entry: entry)), [], false, nil)
        case .conflict(_, let copyPath, let copyEntry):
            // 並行作成の衝突（リモートが同 path を先に確定）: ローカル新規内容は conflict copy と
            // して上げ済みなので、作成 item を copy に束ねる（ローカル実体 = copy の内容そのもの・
            // 再取得不要）。正規パスのリモート版は次の enumerateChanges が新 item として配る
            //（modifyItem 競合と同じ「正規パスはリモート勝ち」・データ損失ゼロ）。
            AppLogger.fileProvider.notice("createItem: collision with remote — created as conflict copy: \(copyPath, privacy: .private)")
            completion.value(
                FileProviderItem(node: .file(path: copyPath, entry: copyEntry)), [], false, nil)
        }
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
        guard !changedFields.contains(.filename), !changedFields.contains(.parentItemIdentifier) else {
            // 改名 / 移動は Phase 5-4（capability 未許可なので通常は来ない防御・file/dir 共通）。
            progress.completedUnitCount = 1
            completionHandler(nil, [], false, Self.renameUnsupportedError())
            return progress
        }
        let path = ref.path
        let completion = UncheckedSendableBox(value: completionHandler)

        guard !ref.isDirectory else {
            // ディレクトリのメタデータ変更（mtime / タグ等・M5 Phase 5-3）: マニフェストに
            // 保存先が無いので**黙って受理**する（ファイル側のメタデータのみ modify と同じ理由 =
            // remainingFields に残すと fileproviderd が永久再試行する）。権威 = 現ツリーの合成 dir、
            // ツリー外（ローカル仮想フォルダ）は合成 dir を返して温存。
            let task = Task {
                defer { progress.completedUnitCount = progress.totalUnitCount }
                do {
                    let tree = try await services.cache.current().tree
                    let node = tree.node(at: path)
                    if let node, !node.isDirectory {
                        // kind 不一致（stale dir id・実体はファイル）= その dir はもう無い
                        completion.value(nil, [], false, NSFileProviderError(.noSuchItem))
                        return
                    }
                    completion.value(
                        FileProviderItem(node: node ?? .directory(path: path, mtime: nil)),
                        [], false, nil
                    )
                } catch {
                    completion.value(nil, [], false, error)
                }
            }
            progress.cancellationHandler = { task.cancel() }
            return progress
        }

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
            // ディレクトリ削除（M5 Phase 5-3）。dir の baseVersion（"dir"）は per-file ガードに
            // 使えないため、ベース = キャッシュ済みツリーの各ファイル sha（システムが直近に
            // 見ている世代と同源）。ガード本体は RMW 内（`removeFileEntries`）。
            let dirCompletion = UncheckedSendableBox(value: completionHandler)
            let dirPath = ref.path
            let recursive = options.contains(.recursive)
            let task = Task {
                defer { progress.completedUnitCount = progress.totalUnitCount }
                do {
                    let current = try await services.cache.current()
                    let prefix = dirPath + "/"
                    var expected: [String: String] = [:]
                    for (p, node) in current.tree.nodesByPath {
                        guard p.hasPrefix(prefix), case .file(_, let entry) = node else { continue }
                        expected[p] = entry.sha256
                    }
                    guard !expected.isEmpty else {
                        // 追跡ファイルなし = ローカル仮想フォルダ / 既に空・消滅済み。
                        // S3 非接触でローカル削除だけ成立させる（冪等成功）。
                        dirCompletion.value(nil)
                        return
                    }
                    guard recursive else {
                        // 非再帰削除で中身がある → SDK 契約どおり DirectoryNotEmpty
                        //（システムが dir を最新メタデータから再作成する）。
                        dirCompletion.value(NSFileProviderError(.directoryNotEmpty))
                        return
                    }
                    switch try await services.writer.deleteDirectory(expecting: expected) {
                    case .removed(let count):
                        AppLogger.fileProvider.notice("deleteItem(dir): removed \(count) files under \(dirPath, privacy: .private)")
                        dirCompletion.value(nil)
                    case .rejected(let path, _):
                        // 配下にベースより進んだファイル（リモート先行）→ 1 件目で中断済み
                        //（「拒否で即中断」・2026-07-09 ユーザ確定）。SDK 契約: 再帰削除で消せない
                        // 子がいる場合も DirectoryNotEmpty — システムが dir を最新メタデータから
                        // 再作成し、除去済み分の削除は次の enumerateChanges の diff が配る。
                        AppLogger.fileProvider.notice("deleteItem(dir): rejected — remote changed under dir: \(path, privacy: .private)")
                        dirCompletion.value(NSFileProviderError(.directoryNotEmpty))
                    }
                } catch {
                    AppLogger.fileProvider.error("deleteItem(dir) failed: \(String(describing: error), privacy: .private)")
                    dirCompletion.value(error)
                }
            }
            progress.cancellationHandler = { task.cancel() }
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
