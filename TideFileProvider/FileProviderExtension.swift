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
///   createItem（file/folder）+ deleteItem（dir 再帰）+ dir メタデータ modify = Phase 5-3、
///   改名/移動（.filename / .parentItemIdentifier・copyObject による sha 不変の path 移動）
///   = Phase 5-4。これで書込系は全対応。
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
                    if ref.isDirectory, await services.virtualDirs.contains(path) {
                        // 仮想フォルダ（createItem で仮想受理した = レジストリ登録済み）のみ
                        // 合成 dir を返して温存する。noSuchItem を返すとデーモンがローカル
                        // フォルダごと掃除してしまうため（M5 Phase 5-3）。
                        // **レジストリ外のマニフェスト外 dir id は noSuchItem**（M5 Phase 5-4）:
                        // 無条件合成にすると dir move/削除の reconcile 中の照会に生きた item を
                        // 返してしまい、消えたはずの旧 dir が空フォルダとして復活する（実機確定）。
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
                // 実体化バッジ（Issue #65）: ツリー由来の item は報告済み集合基準のフラグ付きで
                // 返す（プレーンで返すと報告済みバッジがメタデータ regress で消えたまま固着する）。
                let reported = await services.materializedReported.snapshot()
                completion.value(BadgeFlags(tree: tree, reported: reported).item(node), nil)
            } catch {
                AppLogger.fileProvider.error("item(for:) failed: \(String(describing: error), privacy: .private)")
                completion.value(nil, Self.wrapForCompletion(error))
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
                    await services.events.append(
                        type: .error, path: path,
                        message: "Materialize failed: integrity verification (size \(written)/\(entry.size))")
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
                // 実体化バッジ（Issue #65）: 返却 item は実体化済みフラグ付き（この瞬間に内容が
                // ローカルに載る）。報告済みレジストリはここでは触らない — 前進は working set の
                // enumerateChanges が単一の報告点（先に足すと祖先 dir のチェック反転差分が
                // 消えてしまう）。didChange → 自己 signal → 差分配信で dir 側も追従する。
                cleanupURL = nil
                // FP 版 Sync Activity（Issue #83）: materialize 成功 = folderSync の download 相当。
                await services.events.append(
                    type: .download, path: path, message: "Materialized (\(written) bytes)")
                completion.value(
                    tmpURL,
                    FileProviderItem(node: .file(path: path, entry: entry), materialized: true),
                    nil)
            } catch {
                AppLogger.fileProvider.error("fetchContents failed: \(String(describing: error), privacy: .private)")
                // キャンセル（ユーザ操作 / システム都合の中断）は正常系なのでイベントにしない。
                if !(error is CancellationError) {
                    await services.events.append(
                        type: .error, path: path, message: "Materialize failed",
                        details: String(describing: error))
                }
                completion.value(nil, nil, Self.wrapForCompletion(error))
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    // MARK: - 実体化バッジ（Issue #65）

    /// システム通知: 実体化セットが変わった（materialize / evict）。live を観測し直し、報告済みと
    /// 食い違えば working set を signal → enumerateChanges が差分（バッジの点灯/消灯 + 祖先 dir の
    /// チェック反転）を配る。**evict（Finder の「ダウンロードを削除」）は拡張の他のコールバックを
    /// 一切経由しない**ため、バッジ消灯はこの経路だけが検知できる（`NSFileProviderReplicatedExtension`
    /// の optional メソッド・SDK ヘッダの反転プロトコル =「システムがこれを呼んだら拡張側が
    /// `enumeratorForMaterializedItems` で列挙する」）。
    func materializedItemsDidChange(completionHandler: @escaping () -> Void) {
        guard let services else {
            completionHandler()
            return
        }
        let completion = UncheckedSendableBox(value: completionHandler)
        Task {
            await services.refreshMaterializedObservation()
            completion.value()
        }
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
            // 同期文脈なので fire-and-forget（イベントは best-effort・path は検証不能なので details へ）
            let filename = itemTemplate.filename
            Task {
                await services.events.append(
                    type: .info, path: nil,
                    message: "Excluded from sync: unsyncable name (kept local)", details: filename)
            }
            progress.completedUnitCount = 1
            completionHandler(nil, [], false, NSFileProviderError(.excludedFromSync))
            return progress
        }
        let contentType = itemTemplate.contentType
        // symlink は絶対に同期しない（セキュリティゲート）— ローカルに残して同期対象外。
        if contentType?.conforms(to: .symbolicLink) == true {
            AppLogger.fileProvider.notice("createItem: symlink excluded from sync: \(path, privacy: .private)")
            Task {
                await services.events.append(
                    type: .info, path: path,
                    message: "Excluded from sync: symbolic link (kept local)")
            }
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
                Task {
                    await services.events.append(
                        type: .info, path: path, message: "Excluded from sync (kept local)")
                }
                progress.completedUnitCount = 1
                completionHandler(nil, [], false, NSFileProviderError(.excludedFromSync))
                return progress
            }
            // 空フォルダのローカル仮想受理（S3 非接触・2026-07-09 ユーザ確定）: マニフェストに
            // ディレクトリエントリは無く、配下にファイルが入った時点で合成 dir として実体化・
            // 同期される。空のままなら他デバイスへ伝播しない（FSEvents モードの「空ディレクトリは
            // 同期しない」と同じ）。id は path 決定的（`d:<path>`）なので、実体化後の合成 dir と
            // 同一 item に収束する。
            //
            // 同 path にマニフェスト **file** が実在する kind 衝突は意図的にチェックしない
            // （PR #59 レビュー #2）: ツリー参照（cache.current()）を挟むと cold 時に S3 往復が
            // 要り「フォルダ作成 = S3 非接触・オフラインでも成功」の利点を失う。並存した場合は
            // 別 id（`d:` と `f:`）の同名 item となり、システムの名前衝突バウンスが解消する。
            //
            // 仮想 dir の mtime 規約（PR #59 レビュー #3・三経路で共通）: **作成時のみテンプレート
            // 値を載せ、再照会（item(for:) / dir メタデータ modifyItem）は nil** — mtime は
            // マニフェストに保存されず再照会時には知り得ないため。metadataVersion が
            // "dir-<日時>" → "dir" へ一度揺れ得るが、contentVersion（"dir"）は不変なので
            // 再取得等の副作用はない（実機 bounce ゼロ確認済み）。実体化後は配下最大 mtime の
            // 合成値に収束する。
            let dirMtime = itemTemplate.contentModificationDate ?? nil
            let dirCompletion = UncheckedSendableBox(value: completionHandler)
            let task = Task {
                defer { progress.completedUnitCount = progress.totalUnitCount }
                // レジストリ登録 = item(for:) / enumerator の合成 dir 温存の根拠（M5 Phase 5-4）
                await services.virtualDirs.add(path)
                dirCompletion.value(
                    FileProviderItem(node: .directory(path: path, mtime: dirMtime)),
                    [], false, nil
                )
            }
            progress.cancellationHandler = { task.cancel() }
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
                    await services.events.append(
                        type: .info, path: path, message: "Excluded from sync (kept local)")
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
                    // 実体化した祖先の仮想フォルダはレジストリ保護を外す（M5 Phase 5-4 —
                    // 残すと「実体化後にリモート削除された dir」を空フォルダとして復活させる）。
                    // 同 path が除外後始末の予約中なら解除（再包含 = 除外の再評価で同期復帰）。
                    await services.virtualDirs.removeAncestors(of: path)
                    await services.exclusionCleanups.removeSubtree(at: path)
                    await Self.completeCreate(
                        outcome, path: path, events: services.events, completion: completion)
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
                await services.virtualDirs.removeAncestors(of: path)
                await services.exclusionCleanups.removeSubtree(at: path)
                await Self.completeCreate(
                    outcome, path: path, events: services.events, completion: completion)
            } catch {
                AppLogger.fileProvider.error("createItem failed: \(String(describing: error), privacy: .private)")
                if !(error is CancellationError) {
                    await services.events.append(
                        type: .error, path: path, message: "Create failed",
                        details: String(describing: error))
                }
                completion.value(nil, [], false, Self.wrapForCompletion(error))
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    /// createItem の書込結果 → completion 変換（内容あり/なしの 2 経路で共用）。
    /// FP 版 Sync Activity（Issue #83）のイベント記録もここに合流させる。
    private static func completeCreate(
        _ outcome: ExtensionWriter.ModifyOutcome,
        path: String,
        events: FPEventLog,
        completion: UncheckedSendableBox<(NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void>
    ) async {
        // 実体化バッジ（Issue #65）: いずれも内容がローカルにある（今書いたファイルそのもの）
        // ので実体化済みフラグ付きで返す。レジストリの前進は enumerateChanges（単一の報告点）。
        switch outcome {
        case .written(let entry):
            await events.append(
                type: .upload, path: path, message: "Created (\(entry.size) bytes)")
            completion.value(
                FileProviderItem(node: .file(path: path, entry: entry), materialized: true),
                [], false, nil)
        case .conflict(_, let copyPath, let copyEntry):
            // 並行作成の衝突（リモートが同 path を先に確定）: ローカル新規内容は conflict copy と
            // して上げ済みなので、作成 item を copy に束ねる（ローカル実体 = copy の内容そのもの・
            // 再取得不要）。正規パスのリモート版は次の enumerateChanges が新 item として配る
            //（modifyItem 競合と同じ「正規パスはリモート勝ち」・データ損失ゼロ）。
            AppLogger.fileProvider.notice("createItem: collision with remote — created as conflict copy: \(copyPath, privacy: .private)")
            await events.append(
                type: .conflict, path: path, message: "Created as conflict copy → \(copyPath)")
            completion.value(
                FileProviderItem(node: .file(path: copyPath, entry: copyEntry), materialized: true),
                [], false, nil)
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
        let path = ref.path
        let completion = UncheckedSendableBox(value: completionHandler)

        if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
            // 改名 / 移動（M5 Phase 5-4）。sha 不変の path 移動 = copyObject + 二相 RMW。
            return handleMove(
                item: item, ref: ref, baseVersion: version, changedFields: changedFields,
                newContents: newContents, services: services,
                progress: progress, completion: completion
            )
        }

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
                    if let node {
                        // 実体化バッジ（Issue #65）: チェック中の dir をプレーンで返すと
                        // マニフェスト無変化のままバッジが消えて固着する（dir メタデータ modify は
                        // 世代を進めない）ため、報告済み集合基準のフラグを維持する。
                        let reported = await services.materializedReported.snapshot()
                        completion.value(
                            BadgeFlags(tree: tree, reported: reported).item(node), [], false, nil)
                    } else {
                        completion.value(
                            FileProviderItem(node: .directory(path: path, mtime: nil)),
                            [], false, nil)
                    }
                } catch {
                    completion.value(nil, [], false, Self.wrapForCompletion(error))
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
                    // 実体化バッジ（Issue #65）: 報告済み集合基準のフラグを維持（固着防止）。
                    let reported = await services.materializedReported.snapshot()
                    completion.value(
                        BadgeFlags(tree: tree, reported: reported).item(node), [], false, nil)
                } catch {
                    completion.value(nil, [], false, Self.wrapForCompletion(error))
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
        let baseSha = FileProviderWritePolicy.baseSha(
            contentVersion: version.contentVersion, metadataVersion: version.metadataVersion)
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
                    // 実体化バッジ（Issue #65）: 編集内容 = ローカル実体なので実体化済み。
                    await services.events.append(
                        type: .upload, path: path, message: "Uploaded (\(entry.size) bytes)")
                    completion.value(
                        FileProviderItem(node: .file(path: path, entry: entry), materialized: true),
                        [], false, nil)
                case .conflict(let remote, let copyPath, _):
                    // 正規パスはリモート版が勝つ（FSEvents 側と対称）。shouldFetchContent=true で
                    // システムにリモート内容を取り直させる。ローカル編集は conflict copy として
                    // 自世代に反映済み → 直後の enumerateChanges で新 item として出現する。
                    AppLogger.fileProvider.notice("modifyItem: upload conflict — local edit preserved as copy: \(copyPath, privacy: .private)")
                    await services.events.append(
                        type: .conflict, path: path,
                        message: "Upload conflict — local edit preserved as copy → \(copyPath)")
                    completion.value(
                        FileProviderItem(node: .file(path: path, entry: remote), materialized: true),
                        [], true, nil)
                }
            } catch {
                AppLogger.fileProvider.error("modifyItem failed: \(String(describing: error), privacy: .private)")
                if !(error is CancellationError) {
                    await services.events.append(
                        type: .error, path: path, message: "Upload failed",
                        details: String(describing: error))
                }
                completion.value(nil, [], false, Self.wrapForCompletion(error))
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    /// modifyItem の改名 / 移動分岐（M5 Phase 5-4・rename/reparent）。
    ///
    /// - 返却 item は**新 id**（`f:`/`d:` + 新 path）を運ぶ — SDK の merge 機構
    ///   （「返却 item の itemIdentifier をシステムが採用し、他方をディスクから外す」）を
    ///   path ベース id の rebind に使う（PoC 最大の未知点・実機実証項目）。
    /// - 除外対象名への改名は `ExcludedFromSync` = ローカルで改名成立 + 同期対象外へ
    ///   （システムが続けて旧 id の deleteItem を発行 → 旧 entry が S3 から外れる =
    ///   FSEvents モードの「旧 path 削除伝播 + 新 path 非同期」と対称・2026-07-09 ユーザ確定）。
    /// - dir move の除外判定は**新 dir パス単位のみ**（機密網 + ユーザパターンの dir 一致）。
    ///   子ごとの新 path パターン一致は意図的に適用しない — FP では旧 id の削除配信が
    ///   ローカル実体も消すため、「ローカル温存で非同期」を per-child に再現できない
    ///   （dir 単位の ExcludedFromSync なら実体温存で全体が同期外 = 損失ゼロ）。docs/08 参照。
    /// - `.sourceChanged`（リモート先行）は一時エラー返却 = 新旧両存のまま。リモート変化が
    ///   届いて baseVersion が追いつくと再試行の move が「進んだ後の内容」で自己回復する。
    private func handleMove(
        item: NSFileProviderItem,
        ref: (path: String, isDirectory: Bool),
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        newContents: URL?,
        services: ExtensionServices,
        progress: Progress,
        completion: UncheckedSendableBox<(NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void>
    ) -> Progress {
        let oldPath = ref.path
        // 新しい親: .parentItemIdentifier が変わっていれば template の親 id（Tide の dir id
        // のみ受理・trash 等は未対応）、変わっていなければ旧 path の親。
        let newParentPath: String
        if changedFields.contains(.parentItemIdentifier) {
            guard let parent = item.parentItemIdentifier.tidePathAndKind, parent.isDirectory else {
                progress.completedUnitCount = 1
                completion.value(nil, [], false, NSFileProviderError(.noSuchItem))
                return progress
            }
            newParentPath = parent.path
        } else {
            let components = oldPath.split(separator: "/").dropLast()
            newParentPath = components.joined(separator: "/")
        }
        // パス合成は createItem と同一のゲート（構造検証 → 網羅検証）。検証不能な新名は
        // 除外扱い（nil = Task 内の除外分岐へ合流し、旧 entry の自前除去 → ExcludedFromSync）。
        let validNewPath: String? = {
            guard
                let p = FileProviderWritePolicy.childPath(
                    parentPath: newParentPath, filename: item.filename),
                (try? PathValidator.validateRelativePath(p)) != nil
            else { return nil }
            return p
        }()
        if validNewPath == nil {
            AppLogger.fileProvider.notice("modifyItem(move): unsyncable new name (excluded): \(item.filename, privacy: .private)")
        }
        guard validNewPath != oldPath else {
            // 実質 no-op（同一 path への「移動」）。この分岐は実際に踏める — Swift の
            // `String ==` は正準等価（NFC/NFD 同一視）のため、正規化差だけの rename が該当する。
            // **`.contents` が同時に立っている複合 modifyItem はここで握りつぶさない**
            //（PR #60 レビュー #4: 全フィールド消化で返すと新内容が未アップロードのまま
            // 「同期済み」になる無エラー乖離）— rename は no-op とし、内容は通常の
            // modifyFileContents 経路（modifyItem の .contents 分岐と同じ帰結写像）で処理する。
            let noopContents =
                changedFields.contains(.contents) && !ref.isDirectory ? newContents : nil
            let boxedNoopURL = UncheckedSendableBox(value: noopContents)
            let noopModified = item.contentModificationDate ?? nil
            let noopBase = FileProviderWritePolicy.baseSha(
                contentVersion: version.contentVersion, metadataVersion: version.metadataVersion)
            let task = Task {
                defer { progress.completedUnitCount = progress.totalUnitCount }
                do {
                    if let contentsURL = boxedNoopURL.value {
                        let outcome = try await services.writer.modifyFileContents(
                            path: oldPath, contentsURL: contentsURL,
                            baseSha: noopBase, contentModified: noopModified
                        )
                        switch outcome {
                        case .written(let entry):
                            // 実体化バッジ（Issue #65）: 編集内容 = ローカル実体（.written/.conflict
                            // とも modifyItem の .contents 分岐と同じ帰結写像）。
                            await services.events.append(
                                type: .upload, path: oldPath,
                                message: "Uploaded (\(entry.size) bytes)")
                            completion.value(
                                FileProviderItem(
                                    node: .file(path: oldPath, entry: entry), materialized: true),
                                [], false, nil)
                        case .conflict(let remote, let copyPath, _):
                            AppLogger.fileProvider.notice("modifyItem(move noop): upload conflict — local edit preserved as copy: \(copyPath, privacy: .private)")
                            await services.events.append(
                                type: .conflict, path: oldPath,
                                message: "Upload conflict — local edit preserved as copy → \(copyPath)")
                            completion.value(
                                FileProviderItem(
                                    node: .file(path: oldPath, entry: remote), materialized: true),
                                [], true, nil)
                        }
                        return
                    }
                    let tree = try await services.cache.current().tree
                    if let node = tree.node(at: oldPath) {
                        // 実体化バッジ（Issue #65）: 報告済み集合基準のフラグを維持（固着防止）。
                        let reported = await services.materializedReported.snapshot()
                        completion.value(
                            BadgeFlags(tree: tree, reported: reported).item(node), [], false, nil)
                    } else {
                        completion.value(
                            FileProviderItem(node: .directory(path: oldPath, mtime: nil)),
                            [], false, nil)
                    }
                } catch {
                    completion.value(nil, [], false, Self.wrapForCompletion(error))
                }
            }
            progress.cancellationHandler = { task.cancel() }
            return progress
        }

        let hasNewContents = changedFields.contains(.contents)
        let boxedURL = UncheckedSendableBox(value: newContents)
        let contentModified = item.contentModificationDate ?? nil
        let isDirectory = ref.isDirectory
        let task = Task {
            defer { progress.completedUnitCount = progress.totalUnitCount }
            do {
                let current = try await services.cache.current()

                if isDirectory {
                    let prefix = oldPath + "/"
                    var children: [(from: String, entry: ManifestFileEntry)] = []
                    for (p, node) in current.tree.nodesByPath {
                        guard p.hasPrefix(prefix), case .file(_, let entry) = node else { continue }
                        children.append((from: p, entry: entry))
                    }
                    // 除外判定: 検証不能な新名 / 機密網（component 一致）/ ユーザパターンの
                    // dir 一致（`<dir>/` 評価）→ subtree ごと同期対象外（実体はローカル温存）。
                    let excluded: Bool
                    if let newPath = validNewPath {
                        if HardcodedIgnoreRules.shouldIgnore(relativePath: newPath) {
                            excluded = true
                        } else {
                            let layered = try await services.ignore.layeredIgnore(
                                tree: current.tree, anchor: current.anchor)
                            excluded = layered.evaluate(newPath + "/") == .ignored
                        }
                    } else {
                        excluded = true
                    }
                    if excluded {
                        // ExcludedFromSync = ローカルで改名成立・subtree ごと同期対象外。
                        // **マニフェストはここでは触らない** — SDK は除外時に「内容をダウンロード
                        // してから deleteItem を発行」する契約で、先に entry を消すと dataless の
                        // 子が materialize できない殻になる（5-4 実機で確定）。後追い deleteItem
                        //（dir 再帰）は子のベースをツリー現行 sha で取るため追加の予約は不要 =
                        // そのまま受理される。
                        AppLogger.fileProvider.notice("modifyItem(move): dir excluded (excludedFromSync; cleanup via system deleteItem): \(oldPath, privacy: .private)")
                        await services.events.append(
                            type: .info, path: oldPath,
                            message: "Excluded from sync by rename (kept local)")
                        await services.virtualDirs.removeSubtree(at: oldPath)
                        completion.value(nil, [], false, NSFileProviderError(.excludedFromSync))
                        return
                    }
                    let newPath = validNewPath!  // excluded が nil ケースを吸収済み
                    guard current.tree.node(at: newPath) == nil else {
                        completion.value(nil, [], false, NSFileProviderError(.filenameCollision))
                        return
                    }
                    guard !children.isEmpty else {
                        // 仮想フォルダ（マニフェスト非表現）の改名 = ローカル受理のみで成立
                        //（5-3 の空フォルダ姿勢を継承。id は新 path で振り直し = rebind）。
                        // レジストリも subtree ごと追従 + 新 path を登録（旧ビルドで作られた
                        // レジストリ未登録の仮想フォルダも rename を機に保護下へ入れる）。
                        await services.virtualDirs.renameSubtree(from: oldPath, to: newPath)
                        await services.virtualDirs.add(newPath)
                        completion.value(
                            FileProviderItem(node: .directory(path: newPath, mtime: nil)),
                            [], false, nil)
                        return
                    }
                    let descendants = children.map {
                        (from: $0.from, to: newPath + "/" + $0.from.dropFirst(prefix.count),
                         entry: $0.entry)
                    }
                    let oldMtime: Date? = {
                        if case .directory(_, let mtime)? = current.tree.node(at: oldPath) { return mtime }
                        return nil
                    }()
                    switch try await services.writer.moveDirectory(descendants: descendants) {
                    case .moved:
                        AppLogger.fileProvider.notice("modifyItem(move): dir moved (\(descendants.count) files): -> \(newPath, privacy: .private)")
                        await services.events.append(
                            type: .move, path: oldPath,
                            message: "Moved → \(newPath) (\(descendants.count) files)")
                        // 実体化バッジ（Issue #65）: move は内容を動かさないので実体化状態は不変。
                        // 返却 dir のチェックは旧 path（移動前ツリー）の集計を引き継ぎ、報告済み
                        // レジストリは subtree ごと新 path へ追従させる（追従しないと移動直後の
                        // 差分が配下全件の再点灯として再送されるチャーンになる）。
                        let reported = await services.materializedReported.snapshot()
                        let wasChecked = BadgeFlags(tree: current.tree, reported: reported)
                            .isOn(.directory(path: oldPath, mtime: oldMtime))
                        await services.materializedReported.renameSubtree(from: oldPath, to: newPath)
                        // 配下の仮想サブフォルダ（空 dir）のレジストリエントリも新 path へ追従
                        await services.virtualDirs.renameSubtree(from: oldPath, to: newPath)
                        completion.value(
                            FileProviderItem(
                                node: .directory(path: newPath, mtime: oldMtime),
                                materialized: wasChecked),
                            [], false, nil)
                    case .destinationOccupied:
                        completion.value(nil, [], false, NSFileProviderError(.filenameCollision))
                    case .sourceChanged(let path, _):
                        AppLogger.fileProvider.notice("modifyItem(move): source changed under dir (retry later): \(path, privacy: .private)")
                        completion.value(nil, [], false, Self.moveConflictError())
                    }
                    return
                }

                // ファイル: 除外判定は createItem と同一関数・同一優先順位を**新 path**へ適用
                //（検証不能な新名 = validNewPath nil も除外へ合流）。
                let excluded: Bool
                if let newPath = validNewPath {
                    let isTracked = current.tree.node(at: newPath) != nil
                    let layered = try await services.ignore.layeredIgnore(
                        tree: current.tree, anchor: current.anchor)
                    excluded = IgnoreDecision.shouldSkip(
                        relativePath: newPath, isAlreadyTracked: isTracked, matcher: layered)
                } else {
                    excluded = true
                }
                if excluded {
                    // ExcludedFromSync = ローカルで改名成立・同期対象外。マニフェストはここでは
                    // 触らない（先に entry を消すと dataless が materialize できない殻になる —
                    // SDK は除外時に「内容ダウンロード → deleteItem」の順で後始末する）。
                    // 後追い deleteItem の baseVersion は sha 形でない（ローカル保留変更の
                    // 版スタンプ）ことを実機観測したため、この path を**後始末予約**に登録し、
                    // deleteItem 側でツリー現行 sha をベースに受理する。
                    await services.exclusionCleanups.add(oldPath)
                    AppLogger.fileProvider.notice("modifyItem(move): excluded new name (excludedFromSync; cleanup reserved): \(oldPath, privacy: .private)")
                    await services.events.append(
                        type: .info, path: oldPath,
                        message: "Excluded from sync by rename (kept local)")
                    completion.value(nil, [], false, NSFileProviderError(.excludedFromSync))
                    return
                }
                let newPath = validNewPath!  // excluded が nil ケースを吸収済み
                if let node = current.tree.node(at: newPath), node.isDirectory {
                    // kind 衝突（新 path にマニフェスト dir が実在）→ 名前バウンス
                    completion.value(nil, [], false, NSFileProviderError(.filenameCollision))
                    return
                }
                guard case .file(_, let entry)? = current.tree.node(at: oldPath) else {
                    // 旧 entry がもう無い（stale id / 他デバイスが先に削除）
                    completion.value(nil, [], false, NSFileProviderError(.noSuchItem))
                    return
                }
                let outcome = try await services.writer.moveFile(
                    from: oldPath, to: newPath, entry: entry,
                    contentsURL: hasNewContents ? boxedURL.value : nil,
                    contentModified: contentModified
                )
                switch outcome {
                case .moved(let newEntry):
                    // 返却 item は新 id（rebind）。newEntry は単一 move では必ず非 nil。
                    // 実体化バッジ（Issue #65）: move は内容を動かさない = 実体化状態は旧 path を
                    // 引き継ぎ、報告済みレジストリも新 path へ追従（チャーン防止）。
                    let entry = newEntry ?? entry
                    await services.events.append(
                        type: .move, path: oldPath, message: "Moved → \(newPath)")
                    let wasMaterialized = await services.materializedReported.snapshot()
                        .contains(oldPath)
                    await services.materializedReported.renameSubtree(from: oldPath, to: newPath)
                    completion.value(
                        FileProviderItem(
                            node: .file(path: newPath, entry: entry),
                            materialized: wasMaterialized),
                        [], false, nil)
                case .destinationOccupied:
                    completion.value(nil, [], false, NSFileProviderError(.filenameCollision))
                case .sourceChanged(let path, _):
                    AppLogger.fileProvider.notice("modifyItem(move): source changed (retry later): \(path, privacy: .private)")
                    completion.value(nil, [], false, Self.moveConflictError())
                }
            } catch {
                AppLogger.fileProvider.error("modifyItem(move) failed: \(String(describing: error), privacy: .private)")
                if !(error is CancellationError) {
                    await services.events.append(
                        type: .error, path: oldPath, message: "Move failed",
                        details: String(describing: error))
                }
                completion.value(nil, [], false, Self.wrapForCompletion(error))
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
                        await services.virtualDirs.removeSubtree(at: dirPath)
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
                        await services.events.append(
                            type: .delete, path: dirPath, message: "Deleted folder (\(count) files)")
                        await services.virtualDirs.removeSubtree(at: dirPath)
                        // 実体化バッジ（Issue #65）: 消えた subtree の報告済みエントリも掃除
                        await services.materializedReported.removeSubtree(at: dirPath)
                        dirCompletion.value(nil)
                    case .removedIndexStale(let count, let detail):
                        // 部分完了（Issue #91）: 除去確定分（count 件）の marker は発行済み =
                        // 孤児なし。エラーで返して fileproviderd の再試行に残分削除 +
                        // stale index 治癒（.alreadyGone 収束時の突合修復）を委ねる。
                        // virtualDirs / バッジの subtree 掃除は完了時の再試行側に任せる。
                        AppLogger.fileProvider.error("deleteItem(dir): partial completion (index update pending, \(count) files removed) under \(dirPath, privacy: .private): \(detail, privacy: .private)")
                        await services.events.append(
                            type: .delete, path: dirPath,
                            message: "Deleted folder (\(count) files; index update pending)")
                        dirCompletion.value(Self.wrapForCompletion(
                            SyncError.indexUpdateFailedAfterCommit(detail)))
                    case .rejected(let path, _):
                        // 配下にベースより進んだファイル（リモート先行）→ 1 件目で中断済み
                        //（「拒否で即中断」・2026-07-09 ユーザ確定）。SDK 契約: 再帰削除で消せない
                        // 子がいる場合も DirectoryNotEmpty — システムが dir を最新メタデータから
                        // 再作成し、除去済み分の削除は次の enumerateChanges の diff が配る。
                        AppLogger.fileProvider.notice("deleteItem(dir): rejected — remote changed under dir: \(path, privacy: .private)")
                        await services.events.append(
                            type: .info, path: dirPath,
                            message: "Delete rejected (remote changed under folder)")
                        dirCompletion.value(NSFileProviderError(.directoryNotEmpty))
                    }
                } catch {
                    AppLogger.fileProvider.error("deleteItem(dir) failed: \(String(describing: error), privacy: .private)")
                    if !(error is CancellationError) {
                        await services.events.append(
                            type: .error, path: dirPath, message: "Delete failed",
                            details: String(describing: error))
                    }
                    dirCompletion.value(Self.wrapForCompletion(error))
                }
            }
            progress.cancellationHandler = { task.cancel() }
            return progress
        }
        let baseSha = FileProviderWritePolicy.baseSha(
            contentVersion: version.contentVersion, metadataVersion: version.metadataVersion)
        let completion = UncheckedSendableBox(value: completionHandler)
        let task = Task {
            defer { progress.completedUnitCount = progress.totalUnitCount }
            do {
                // 除外後始末の予約（M5 Phase 5-4）: `ExcludedFromSync` を返した path への
                // システム後始末 deleteItem は baseVersion が sha 形でない（ローカル保留変更の
                // 版スタンプ・実機観測）ため、ベースをツリー現行 sha に切り替えて受理する。
                // RMW ガード自体は維持 = 読み替え後にリモートが進んでいれば従来どおり拒否。
                // 読み替えは **baseSha が両 version から復元できなかったときだけ**
                //（PR #60 レビュー #1）: 後始末が発行されないまま予約が残留しても（典型 =
                // 予約後のドメイン作り直し）、有効な base を運ぶ将来の正当な deleteItem の
                // ガードは弱めない（metadataVersion フォールバックで sha が取れるなら常に
                // そちらを優先し、この読み替えは不発になる = どちらに転んでも正しい側）。
                var effectiveBase = baseSha
                var isCleanup = false
                if baseSha == nil {
                    isCleanup = await services.exclusionCleanups.contains(ref.path)
                }
                if isCleanup,
                   case .file(_, let entry)? =
                       (try await services.cache.current()).tree.node(at: ref.path) {
                    effectiveBase = entry.sha256
                }
                switch try await services.writer.deleteFile(path: ref.path, baseSha: effectiveBase) {
                case .removedIndexStale(let detail):
                    // 部分完了（Issue #91）: 削除はマニフェスト真実として確定・marker 発行済み =
                    // 孤児なし。イベントは実削除として記録し、エラーで返して fileproviderd の
                    // 再試行（.alreadyGone 収束時の突合修復）に stale index の治癒を委ねる。
                    AppLogger.fileProvider.error("deleteItem: partial completion (index update pending): \(ref.path, privacy: .private): \(detail, privacy: .private)")
                    await services.events.append(
                        type: .delete, path: ref.path, message: "Deleted (index update pending)")
                    completion.value(Self.wrapForCompletion(
                        SyncError.indexUpdateFailedAfterCommit(detail)))
                case .removed:
                    await services.events.append(type: .delete, path: ref.path, message: "Deleted")
                    fallthrough
                case .alreadyGone:
                    // 予約の掃除は成功時に無条件（読み替え不発 = 有効 base で消えた後始末でも
                    // 残留させない。未予約 path への removeSubtree は no-op）。
                    // イベント記録（Issue #83）は実削除（.removed）のみ — alreadyGone は冪等
                    // no-op で活動が無い。
                    await services.exclusionCleanups.removeSubtree(at: ref.path)
                    // 実体化バッジ（Issue #65）: 消えた path の報告済みエントリも掃除
                    await services.materializedReported.removeSubtree(at: ref.path)
                    if isCleanup {
                        AppLogger.fileProvider.notice("deleteItem: exclusion cleanup completed: \(ref.path, privacy: .private)")
                    }
                    completion.value(nil)
                case .rejected(let remote):
                    // リモートがベースより進んでいた → 削除拒否 + 最新 item を添える
                    // （システムが最新版を復元する。「データ損失 < 重複」）。
                    // 診断のため「ベース不明（nil）」と「sha 不一致」を区別してログする。
                    let reason = baseSha == nil ? "base unknown" : "remote changed since base"
                    AppLogger.fileProvider.notice("deleteItem: rejected (\(reason, privacy: .public)): \(ref.path, privacy: .private)")
                    await services.events.append(
                        type: .info, path: ref.path, message: "Delete rejected (\(reason))")
                    // 実体化バッジ（Issue #65）: 添える最新 item も報告済み基準のフラグを維持
                    let isMaterialized = await services.materializedReported.snapshot()
                        .contains(ref.path)
                    completion.value(NSError.fileProviderErrorForRejectedDeletion(
                        of: FileProviderItem(
                            node: .file(path: ref.path, entry: remote),
                            materialized: isMaterialized)
                    ))
                }
            } catch {
                AppLogger.fileProvider.error("deleteItem failed: \(String(describing: error), privacy: .private)")
                if !(error is CancellationError) {
                    await services.events.append(
                        type: .error, path: ref.path, message: "Delete failed",
                        details: String(describing: error))
                }
                completion.value(Self.wrapForCompletion(error))
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

    /// completion へ渡すエラーを SDK 規約ドメイン（NSCocoaErrorDomain / NSFileProviderErrorDomain）
    /// へ包む。規約外ドメイン（SyncError / MoveError 等の Swift エラー）を素通しすると
    /// fileproviderd が CRIT fault を吐く（M5 Phase 5-4 実機で観測。挙動は同じ一時エラー扱い
    /// だが規約違反）。SDK ヘッダの指示どおり NSXPCConnectionReplyInvalid + NSUnderlyingErrorKey。
    private static func wrapForCompletion(_ error: Error) -> Error {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain || ns.domain == NSFileProviderErrorDomain {
            return error
        }
        return NSError(
            domain: NSCocoaErrorDomain, code: NSXPCConnectionReplyInvalid,
            userInfo: [NSUnderlyingErrorKey: ns]
        )
    }

    /// move の `.sourceChanged`（リモート先行で新旧両存のまま中断）用の一時エラー。
    /// fileproviderd は任意のエラーを一時扱いで再試行する — リモート変化の取り込みで
    /// baseVersion が追いつけば再試行の move が自己回復する（`ExtensionWriter.MoveOutcome` 参照）。
    private static func moveConflictError() -> Error {
        NSError(
            domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
            userInfo: [
                NSLocalizedDescriptionKey:
                    String(localized: "The item changed remotely while moving. The move will be retried.")
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
