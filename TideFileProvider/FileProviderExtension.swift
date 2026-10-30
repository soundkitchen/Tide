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
                // kind 不一致（id は f: なのに tree ではディレクトリ・パッケージ等）は「その kind の item は
                // もう無い」= noSuchItem（kind 変化後の stale 旧 id が必ず通る正常系なので notice。
                // path 自体はツリーに実在するため「not in manifest tree」ログとは分ける —
                // 共用すると shard に entry が在るのに無いと出る誤診誘導になる。PR #57 レビュー #3）。
                guard node.kind == ref.kind else {
                    AppLogger.fileProvider.notice("item(for:): kind mismatch (stale id, noSuchItem): \(path, privacy: .private)")
                    completion.value(nil, NSFileProviderError(.noSuchItem))
                    return
                }
                // 実体化バッジ（Issue #65）: ツリー由来の item は伝え済み（報告済み + 返却分）基準のフラグ付きで
                // 返す（プレーンで返すと報告済みバッジがメタデータ regress で消えたまま固着する）。
                let told = await services.toldMaterialized()
                completion.value(BadgeFlags(tree: tree, told: told).item(node), nil)
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
                let node = tree.node(at: path)
                // 一時ファイルは system 推奨のドメイン用 tmp（同一ボリューム）へ書く
                let tmpDir = (try? NSFileProviderManager(for: domain)?.temporaryDirectoryURL())
                    ?? FileManager.default.temporaryDirectory
                let tmpURL = tmpDir.appendingPathComponent("fetch-\(UUID().uuidString)")

                if ref.isPackage, case .package(_, let members, _, _)? = node, let node {
                    // パッケージ（#140）: 中身をファイルごとに一時フォルダへ組み立て、フォルダの URL を
                    // 返す（2026-10-30 PoC で fileproviderd の受理を実機確定。SDK ヘッダは「通常ファイル」
                    // とだけ書くので、ここは文書化されていない挙動に依っている）。
                    progress.totalUnitCount = max(members.values.reduce(0) { $0 + $1.size }, 1)
                    try FileManager.default.createDirectory(at: tmpURL, withIntermediateDirectories: false)
                    cleanupURL = tmpURL
                    // 置き場所を先に順に決めて空のファイルで押さえる（大文字小文字だけ違う中身が重なると
                    // 上書きになる = 一部が黙って欠けるので、並行に取る前に見つけて検証失敗扱いにする）。
                    let sorted = members.sorted(by: { $0.key < $1.key })
                    var placed: [(member: String, entry: ManifestFileEntry, url: URL)] = []
                    for (member, entry) in sorted {
                        // 中身の相対パスはリモート由来 = PathValidator を通して一時フォルダの外へ出さない。
                        let memberURL = try PathValidator.resolveForWrite(relativePath: member, syncRoot: tmpURL)
                        try FileManager.default.createDirectory(
                            at: memberURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        guard !FileManager.default.fileExists(atPath: memberURL.path),
                              FileManager.default.createFile(atPath: memberURL.path, contents: nil)
                        else {
                            await Self.reportPackageMemberFailure(
                                path: path, member: member, detail: "size 0/\(entry.size)", services: services)
                            completion.value(nil, nil, Self.integrityError())
                            return
                        }
                        placed.append((member, entry, memberURL))
                    }
                    // 中身は限られた数だけ並行に取る（小さい中身が数千件あるパッケージを順に取ると数分かかる・
                    // PR #152 レビュー指摘 9）。進み具合は中身ごとの子の Progress で親へ積む。
                    let s3 = services.s3
                    let fetched = try await ExtensionWriter.mapConcurrently(placed) { placed in
                        let child = Progress(
                            totalUnitCount: max(placed.entry.size, 1), parent: progress,
                            pendingUnitCount: placed.entry.size)
                        let outcome = try await Self.fetchVerified(
                            s3: s3, path: path + "/" + placed.member, entry: placed.entry, to: placed.url,
                            progress: child, completedBefore: 0)
                        child.completedUnitCount = child.totalUnitCount
                        return outcome
                    }
                    var completed: Int64 = 0
                    for (placed, outcome) in zip(placed, fetched) {
                        guard case .fetched = outcome else {
                            // 中身が 1 つでも取れない・合わないときは noSuchItem に**しない**（デーモンが
                            // パッケージごと item を消す）。I/O エラーで後の再試行に回す。
                            let detail = switch outcome {
                            case .mismatch(let written): "size \(written)/\(placed.entry.size)"
                            default: "object not found"
                            }
                            await Self.reportPackageMemberFailure(
                                path: path, member: placed.member, detail: detail, services: services)
                            completion.value(nil, nil, Self.integrityError())
                            return
                        }
                        completed += placed.entry.size
                        // 中身の更新日時もマニフェストに揃える（パッケージ自体の日付は item が運ぶ）。
                        if let mtime = ISO8601.parse(placed.entry.mtime) {
                            try? FileManager.default.setAttributes(
                                [.modificationDate: mtime], ofItemAtPath: placed.url.path)
                        }
                    }
                    cleanupURL = nil
                    await services.events.append(
                        type: .download, path: path,
                        message: "Materialized package (\(members.count) files, \(completed) bytes)")
                    let materialized = await services.returnedMaterializedFlag(for: path)
                    completion.value(tmpURL, FileProviderItem(node: node, materialized: materialized), nil)
                    return
                }

                guard !ref.isPackage, case .file(_, let entry)? = node else {
                    // noSuchItem を返すとデーモンはプレースホルダごと item を削除する（実機確認）。
                    // 本当に「無い」時以外に返さないこと。診断のため必ずログを残す。
                    AppLogger.fileProvider.error("fetchContents: path not in manifest tree (noSuchItem): \(path, privacy: .private)")
                    completion.value(nil, nil, NSFileProviderError(.noSuchItem))
                    return
                }
                progress.totalUnitCount = max(entry.size, 1)
                cleanupURL = tmpURL
                switch try await Self.fetchVerified(
                    s3: services.s3, path: path, entry: entry, to: tmpURL,
                    progress: progress, completedBefore: 0)
                {
                case .notFound:
                    // 最新版も無い＝本当に消えている時だけ noSuchItem（デーモンが item を削除する）
                    AppLogger.fileProvider.error("fetchContents: object not found on S3 (noSuchItem): \(path, privacy: .private)")
                    completion.value(nil, nil, NSFileProviderError(.noSuchItem))
                    return
                case .mismatch(let written):
                    // 不一致は noSuchItem では**なく** I/O エラー（item を消させず後で再試行可能に）。
                    AppLogger.fileProvider.error("fetchContents verification failed for \(path, privacy: .private) (size \(written)/\(entry.size))")
                    await services.events.append(
                        type: .error, path: path,
                        message: "Materialize failed: integrity verification (size \(written)/\(entry.size))")
                    completion.value(nil, nil, Self.integrityError())
                    return
                case .fetched:
                    break
                }

                // 成功: tmp はシステムが引き取るので掃除対象から外す（Progress 完了は Task 冒頭の defer）
                // 実体化バッジ（Issue #65）: 返却 item は実体化済みフラグ付き（この瞬間に内容が
                // ローカルに載る）。報告済みレジストリはここでは触らない — 前進は working set の
                // enumerateChanges が単一の報告点（先に足すと祖先 dir のチェック反転差分が
                // 消えてしまう）。didChange → 自己 signal → 差分配信で dir 側も追従する。
                cleanupURL = nil
                // FP 版 Sync Activity（Issue #83）: materialize 成功 = folderSync の download 相当。
                await services.events.append(
                    type: .download, path: path, message: "Materialized (\(entry.size) bytes)")
                let materialized = await services.returnedMaterializedFlag(for: path)
                completion.value(
                    tmpURL,
                    FileProviderItem(node: .file(path: path, entry: entry), materialized: materialized),
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

    /// `fetchVerified` の結果。
    private enum FetchedObject {
        case fetched
        /// 最新版も無い（404 系）。
        case notFound
        /// サイズか SHA-256 がマニフェストと合わない。
        case mismatch(written: Int64)
    }

    /// `files/<path>` を `url`（新しく作る）へ取得し、サイズと SHA-256 をマニフェストと照らす
    /// （Downloader と同じ commit 前検証）。`progress` は `completedBefore` + 書いたバイト数まで進める。
    ///
    /// マニフェストが指す版を第一候補で取得する（enumerate と fetch の間に最新版が変わっても、
    /// 提示した itemVersion と中身が食い違わない）。その版が消えている場合（ライフサイクルの旧版失効・
    /// stale な manifest versionId）は最新版へフォールバックする — 内容の同一性は SHA-256 の照合が保証する。
    private static func fetchVerified(
        s3: TideS3Client, path: String, entry: ManifestFileEntry, to url: URL,
        progress: Progress, completedBefore: Int64
    ) async throws -> FetchedObject {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        // 1 回ぶんのストリーミング取得（先頭から書き直し）。404 系は nil。
        func download(_ versionId: String?) async throws -> (sha: String, written: Int64)? {
            try handle.truncate(atOffset: 0)
            var hasher = SHA256()
            var written: Int64 = 0
            progress.completedUnitCount = completedBefore
            let result = try await s3.streamObject(
                key: "files/\(path)", versionId: versionId, rangeStart: nil
            ) { chunk in
                if progress.isCancelled { throw CancellationError() }
                hasher.update(data: chunk)
                try handle.write(contentsOf: chunk)
                written += Int64(chunk.count)
                progress.completedUnitCount = completedBefore + written
            }
            guard result != nil else { return nil }
            return (HashCalculator.hex(hasher.finalize()), written)
        }

        var outcome = try await download(entry.s3VersionId)
        if outcome == nil, entry.s3VersionId != nil {
            AppLogger.fileProvider.notice("fetchContents: pinned version missing; falling back to latest: \(path, privacy: .private)")
            outcome = try await download(nil)
        }
        guard let (sha, written) = outcome else { return .notFound }
        try handle.close()
        guard written == entry.size, sha == entry.sha256 else { return .mismatch(written: written) }
        return .fetched
    }

    /// パッケージの中身の取得・検証の失敗を記録する（#140）。
    private static func reportPackageMemberFailure(
        path: String, member: String, detail: String, services: ExtensionServices
    ) async {
        AppLogger.fileProvider.error("fetchContents: package member failed verification \(path, privacy: .private)/\(member, privacy: .private) (\(detail, privacy: .private))")
        await services.events.append(
            type: .error, path: path,
            message: "Materialize failed: integrity verification of a package member (\(detail))",
            details: member)
    }

    /// 取得した中身がマニフェストと合わないときのエラー（item を消させない I/O エラー）。
    private static func integrityError() -> Error {
        NSError(
            domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError,
            userInfo: [
                NSLocalizedDescriptionKey:
                    String(localized: "Downloaded content failed integrity verification.")
            ]
        )
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
            // 同期文脈なので fire-and-forget（イベントは best-effort・path は検証不能なので details へ）。
            // details は親フォルダを含む表示用のパス（通知の重複判定の鍵にもなる・#147）。
            let filename = itemTemplate.filename
            let displayPath = FileProviderWritePolicy.displayPath(parentPath: parent.path, filename: filename)
            Task {
                await services.events.append(
                    type: .info, path: nil,
                    message: "Excluded from sync: unsyncable name (kept local)", details: displayPath,
                    notice: .unsyncableName)
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
                    message: "Excluded from sync: symbolic link (kept local)", notice: .symbolicLink)
            }
            progress.completedUnitCount = 1
            completionHandler(nil, [], false, NSFileProviderError(.excludedFromSync))
            return progress
        }

        // パッケージ（#140）: フォルダの判定より先に見る（パッケージ型は `.directory` にも適合する）。
        // ツリーの判定（`PackageClassifier.active`）もパッケージとみなすときだけ（食い違うと、書いた後の
        // ツリーでフォルダに見え、返した item と種類が合わない）。
        if contentType?.conforms(to: .package) == true,
           PackageClassifier.active.isPackage(name: itemTemplate.filename) {
            return createPackage(
                path: path, contents: url, mayAlreadyExist: options.contains(.mayAlreadyExist),
                services: services, progress: progress, completionHandler: completionHandler)
        }

        if contentType?.conforms(to: .directory) == true {
            // 機密網ディレクトリ（.aws / .ssh 等）は subtree ごとローカル温存。単発の
            // ExcludedFromSync で配下の個別 createItem 評価も生じない（FSEvents スキャンの
            // 機密網 dir skipDescendants と対称）。ツリーを引かずに即決する（オフラインでも拒否）。
            // ユーザ `.syncignore` の dir 単位除外は下の Task 内（ツリーと層が要る・#120）。
            // `IgnoreDecision.shouldExcludeDirectory` は「追跡済みあり → 機密網」の順だが、新規
            // フォルダでは機密網を先に即決する（関数側のドキュメントコメント参照）。
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
            // （PR #59 レビュー #2）: 並存した場合は別 id（`d:` と `f:`）の同名 item となり、
            // システムの名前衝突バウンスが解消する。#120 以降はフォルダ単位除外の判定のために
            // ツリー（cache.current()）を引く（cold 時は S3 往復）が、取得に失敗したら受理へ倒す
            // ので「フォルダ作成はオフラインでも成功」は維持している。
            //
            // 仮想 dir の mtime 規約: createItem と modifyItem（メタデータ変更・改名）は、システムが
            // 渡した item の日時をそのまま返す（改名は item に日時が無いので、baseVersion の
            // metadataVersion に符号化しておいた日時を返す）。**modifyItem で nil を返すと、システムはそれを
            // 1970 としてディスクに書く**（Issue #144・2026-10-31 実機確定: 中にファイルを作ると
            // フォルダの日時の modifyItem が来る）。日時はマニフェストにもレジストリにも保存しない
            // ので、item(for:) は nil のまま（そこから 1970 になる経路は未確認・docs/09 #144 項）。
            // 実体化後は配下最大 mtime の合成値に収束する。
            let dirMtime = itemTemplate.contentModificationDate ?? nil
            let dirCompletion = UncheckedSendableBox(value: completionHandler)
            let task = Task {
                defer { progress.completedUnitCount = progress.totalUnitCount }
                // ユーザ `.syncignore` のフォルダ単位除外（#120）: 配下を 1 ファイルずつ除外すると
                // fileproviderd の除外記録がファイル数だけ積もり、拡張の更新のたびに全件再送される。
                if await Self.excludesDirectoryAsWhole(path: path, services: services) {
                    AppLogger.fileProvider.notice("createItem: directory excluded as a whole: \(path, privacy: .private)")
                    await services.events.append(
                        type: .info, path: path, message: "Excluded folder from sync (kept local)")
                    dirCompletion.value(nil, [], false, NSFileProviderError(.excludedFromSync))
                    return
                }
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
                // パッケージも同じ（PR #152 レビュー指摘 3: パッケージの上に単一ファイルの entry を書くと、
                // ツリーでパッケージが勝って誰にも見えないままバックアップから外れる）。
                if let node = current.tree.node(at: path), node.isDirectory || node.isPackage {
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
                        // ファイルの要求にはファイルのノードだけを束ねる（パッケージを返すと種類が合わない）
                        if let node = current.tree.node(at: path), case .file = node {
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
                        outcome, path: path, services: services, completion: completion)
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
                    outcome, path: path, services: services, completion: completion)
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

    /// createItem のパッケージ分岐（#140）。除外の判定はファイルと同じ（機密網 → ユーザ `.syncignore` は
    /// 未追跡のみ・パッケージのパスに当てる）。中身の扱いは `ExtensionWriter.writePackage`。
    private func createPackage(
        path: String, contents url: URL?, mayAlreadyExist: Bool, services: ExtensionServices,
        progress: Progress,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let completion = UncheckedSendableBox(value: completionHandler)
        let boxedURL = UncheckedSendableBox(value: url)
        let task = Task {
            defer { progress.completedUnitCount = progress.totalUnitCount }
            do {
                let current = try await services.cache.current()
                let node = current.tree.node(at: path)
                let layered = try await services.ignore.layeredIgnore(
                    tree: current.tree, anchor: current.anchor)
                if IgnoreDecision.shouldSkip(
                    relativePath: path, isAlreadyTracked: node != nil, matcher: layered) {
                    AppLogger.fileProvider.notice("createItem(package): excluded from sync: \(path, privacy: .private)")
                    await services.events.append(
                        type: .info, path: path, message: "Excluded from sync (kept local)")
                    completion.value(nil, [], false, NSFileProviderError(.excludedFromSync))
                    return
                }
                guard let contentsURL = boxedURL.value else {
                    // 内容の無い再取り込み（dataless の再発見）はマニフェストと突合して束ねる（ファイルと同じ）。
                    // 内容の無い新規作成は中身が無い = マニフェストに表せないのでローカルに残す。
                    if mayAlreadyExist, let node, node.isPackage {
                        completion.value(FileProviderItem(node: node), [], false, nil)
                    } else if mayAlreadyExist {
                        completion.value(nil, [], false, nil)
                    } else {
                        completion.value(nil, [], false, NSFileProviderError(.excludedFromSync))
                    }
                    return
                }
                let outcome = try await services.writer.writePackage(
                    path: path, contentsURL: contentsURL, baseDigest: nil)
                switch outcome {
                case .written(let written), .unchanged(let written):
                    if case .written = outcome {
                        await services.events.append(
                            type: .upload, path: path, message: "Created package (\(written.memberCount) files)")
                    } else {
                        AppLogger.fileProvider.notice("createItem(package): unchanged (idempotent replay): \(path, privacy: .private)")
                    }
                    await services.virtualDirs.removeAncestors(of: path)
                    await services.exclusionCleanups.removeSubtree(at: path)
                    let materialized = await services.returnedMaterializedFlag(for: path)
                    completion.value(FileProviderItem(node: written, materialized: materialized), [], false, nil)
                case .conflict(let copyPath, let copyNode):
                    AppLogger.fileProvider.notice("createItem(package): collision with remote — created as conflict copy: \(copyPath, privacy: .private)")
                    await services.events.append(
                        type: .conflict, path: path, message: "Created as conflict copy → \(copyPath)")
                    await services.virtualDirs.removeAncestors(of: path)
                    let materialized = await services.returnedMaterializedFlag(for: copyPath)
                    completion.value(FileProviderItem(node: copyNode, materialized: materialized), [], false, nil)
                case .excluded(let reason):
                    await Self.recordPackageExclusion(reason, path: path, services: services)
                    completion.value(nil, [], false, NSFileProviderError(.excludedFromSync))
                case .empty:
                    AppLogger.fileProvider.notice("createItem(package): nothing to sync (kept local): \(path, privacy: .private)")
                    completion.value(nil, [], false, NSFileProviderError(.excludedFromSync))
                case .kindCollision:
                    completion.value(nil, [], false, NSFileProviderError(.filenameCollision))
                }
            } catch {
                AppLogger.fileProvider.error("createItem(package) failed: \(String(describing: error), privacy: .private)")
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

    /// パッケージを丸ごと除外したことを記録し、通知の印を付ける（#140・#147 の経路）。
    private static func recordPackageExclusion(
        _ reason: PackageScanner.Exclusion, path: String, services: ExtensionServices
    ) async {
        let notice: FPEventNotice
        let detail: String
        switch reason {
        case .symbolicLink(let member):
            (notice, detail) = (.packageHasUnsyncableItem, "symbolic link: \(member)")
        case .unsupportedItem(let member):
            (notice, detail) = (.packageHasUnsyncableItem, "unsupported item: \(member)")
        case .unsyncableName(let member):
            (notice, detail) = (.packageHasUnsyncableItem, "unsyncable name: \(member)")
        case .tooManyFiles(let limit):
            (notice, detail) = (.packageTooManyFiles, "more than \(limit) files")
        }
        AppLogger.fileProvider.notice("package excluded as a whole (\(detail, privacy: .private)): \(path, privacy: .private)")
        await services.events.append(
            type: .info, path: path, message: "Excluded package from sync (kept local)", details: detail,
            notice: notice)
    }

    /// 新規フォルダをユーザ `.syncignore` でフォルダごと除外するか（createItem 用・#120）。
    /// 判定本体は `IgnoreDecision.shouldExcludeDirectory`。ツリーか `.syncignore` の取得に
    /// 失敗したら false（= 従来どおり受理し、配下は 1 ファイルずつ判定）= オフラインでも
    /// フォルダ作成は成功する。
    private static func excludesDirectoryAsWhole(
        path: String, services: ExtensionServices
    ) async -> Bool {
        do {
            let current = try await services.cache.current()
            let layered = try await services.ignore.layeredIgnore(
                tree: current.tree, anchor: current.anchor)
            return IgnoreDecision.shouldExcludeDirectory(
                relativePath: path,
                hasTrackedDescendants: current.tree.node(at: path) != nil,
                matcher: layered)
        } catch {
            AppLogger.fileProvider.error("createItem: directory exclusion check failed (accepting): \(String(describing: error), privacy: .private)")
            return false
        }
    }

    /// createItem の書込結果 → completion 変換（内容あり/なしの 2 経路で共用）。
    /// FP 版 Sync Activity（Issue #83）のイベント記録もここに合流させる。
    private static func completeCreate(
        _ outcome: ExtensionWriter.ModifyOutcome,
        path: String,
        services: ExtensionServices,
        completion: UncheckedSendableBox<(NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void>
    ) async {
        // 実体化バッジ（Issue #65）: いずれも内容がローカルにある（今書いたファイルそのもの）
        // ので実体化済みフラグ付きで返す。レジストリの前進は enumerateChanges（単一の報告点）。
        // フラグは上限の内側のときだけ付け、返却分の台帳に記録する（Issue #138・
        // `returnedMaterializedFlag`）。
        switch outcome {
        case .written(let entry):
            await services.events.append(
                type: .upload, path: path, message: "Created (\(entry.size) bytes)")
            let materialized = await services.returnedMaterializedFlag(for: path)
            completion.value(
                FileProviderItem(node: .file(path: path, entry: entry), materialized: materialized),
                [], false, nil)
        case .unchanged(let entry):
            // 冪等リプレイ（reimport の問い直し = #93 治癒・クラッシュ後再送）: 何も書いて
            // いないのでアップロードイベントは記録しない（「Created」を出すと Sync Activity が
            // 実書込と区別できない）。identity 返却だけでダエモンの帳簿が再構築される。
            AppLogger.fileProvider.notice("createItem: unchanged (idempotent replay): \(path, privacy: .private)")
            let materialized = await services.returnedMaterializedFlag(for: path)
            completion.value(
                FileProviderItem(node: .file(path: path, entry: entry), materialized: materialized),
                [], false, nil)
        case .conflict(_, let copyPath, let copyEntry):
            // 並行作成の衝突（リモートが同 path を先に確定）: ローカル新規内容は conflict copy と
            // して上げ済みなので、作成 item を copy に束ねる（ローカル実体 = copy の内容そのもの・
            // 再取得不要）。正規パスのリモート版は次の enumerateChanges が新 item として配る
            //（modifyItem 競合と同じ「正規パスはリモート勝ち」・データ損失ゼロ）。
            AppLogger.fileProvider.notice("createItem: collision with remote — created as conflict copy: \(copyPath, privacy: .private)")
            await services.events.append(
                type: .conflict, path: path, message: "Created as conflict copy → \(copyPath)")
            let materialized = await services.returnedMaterializedFlag(for: copyPath)
            completion.value(
                FileProviderItem(node: .file(path: copyPath, entry: copyEntry), materialized: materialized),
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
            // 仮想フォルダの日時は、システムが渡した item の日時をそのまま返す（Issue #144: nil で
            // 返すとシステムが 1970 をディスクに書く。中にファイルを作るとこの経路を必ず通る）。
            let virtualDirMtime = item.contentModificationDate ?? nil
            let task = Task {
                defer { progress.completedUnitCount = progress.totalUnitCount }
                do {
                    let current = try await services.cache.current()
                    let tree = current.tree
                    let node = tree.node(at: path)
                    if let node, !node.isDirectory {
                        // kind 不一致（stale dir id・実体はファイル）= その dir はもう無い
                        completion.value(nil, [], false, NSFileProviderError(.noSuchItem))
                        return
                    }
                    // 受理済みの仮想フォルダを後からフォルダ単位で除外する（#120・既存分の畳み込み）:
                    // #120 以前に受理され配下が 1 ファイルずつ除外されているフォルダは、`touch` 等の
                    // メタデータ変更を契機にここで ExcludedFromSync を返すと、fileproviderd が配下の
                    // 除外記録をフォルダ 1 件に畳む（実機確認 2026-10-16）。システムは続けて後始末の
                    // deleteItem を送るが、それは数十分遅れて届くことがあり、その時点のツリーで
                    // 削除対象を作り直すと、間に他端末が配下へ上げたファイルを S3 から消してしまう
                    // （PR #123 レビュー B1）。そこで除外を返す前に予約（`dirExclusionHolds`）を積み、
                    // 後始末の deleteItem を S3 非接触で完了させる。予約を積めない（上限超過）か
                    // ディスクに保存できない（保存失敗・保存先の無い縮退時 = 再起動で予約が消えうる・
                    // #120 F1）ときは、除外を返さず従来どおり受理する（保証の無い除外はしない）。
                    // ローカルの実体は残る。
                    // `.syncignore` の取得失敗は判定を諦めて従来どおり受理する（メタデータ変更を
                    // エラーにすると fileproviderd が再試行を続ける）。
                    // 仮想フォルダの登録はここでは消さない: 後始末までの間に
                    // `item(for:)` が noSuchItem を返すと、デーモンがローカルのフォルダごと掃除しうる。
                    // 登録の掃除は後始末の deleteItem が行う。
                    if node == nil,
                       let layered = try? await services.ignore.layeredIgnore(
                           tree: tree, anchor: current.anchor),
                       IgnoreDecision.shouldExcludeDirectory(
                           relativePath: path, hasTrackedDescendants: false, matcher: layered) {
                        if await services.dirExclusionHolds.addDurably(path) {
                            AppLogger.fileProvider.notice("modifyItem(dir metadata): directory excluded as a whole: \(path, privacy: .private)")
                            await services.events.append(
                                type: .info, path: path, message: "Excluded folder from sync (kept local)")
                            completion.value(nil, [], false, NSFileProviderError(.excludedFromSync))
                            return
                        }
                        AppLogger.fileProvider.notice("modifyItem(dir metadata): exclusion hold unavailable; accepting instead: \(path, privacy: .private)")
                    }
                    if let node {
                        // 実体化バッジ（Issue #65）: チェック中の dir をプレーンで返すと
                        // マニフェスト無変化のままバッジが消えて固着する（dir メタデータ modify は
                        // 世代を進めない）ため、伝え済み（報告済み + 返却分）基準のフラグを維持する。
                        let told = await services.toldMaterialized()
                        completion.value(
                            BadgeFlags(tree: tree, told: told).item(node), [], false, nil)
                    } else {
                        completion.value(
                            FileProviderItem(node: .directory(path: path, mtime: virtualDirMtime)),
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
                    guard let node = tree.node(at: path), node.kind == ref.kind else {
                        completion.value(nil, [], false, NSFileProviderError(.noSuchItem))
                        return
                    }
                    // 実体化バッジ（Issue #65）: 伝え済み（報告済み + 返却分）基準のフラグを維持（固着防止）。
                    let told = await services.toldMaterialized()
                    completion.value(
                        BadgeFlags(tree: tree, told: told).item(node), [], false, nil)
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
        // 書類の形式の切り替え（#140・Keynote の「ファイルタイプを変更」）: fileproviderd は同じ item の
        // 中身が別の形式になった modifyItem として送ってくる（2026-10-30 実機）。届いた中身の形式
        // （lstat = リンクは追わない）が item の種類と違えば、新しい形式で書いて旧い形式を消す。
        let contentsIsDirectory = Self.isDirectoryNoFollow(newContents)
        if ref.isPackage, contentsIsDirectory == false {
            return modifyFormatChange(
                path: path, contents: newContents, toPackage: false, baseVersion: baseSha,
                contentModified: item.contentModificationDate ?? nil, services: services,
                progress: progress, completion: completion)
        }
        if ref.kind == .file, contentsIsDirectory == true,
           PackageClassifier.active.isPackage(name: (path as NSString).lastPathComponent) {
            return modifyFormatChange(
                path: path, contents: newContents, toPackage: true, baseVersion: baseSha,
                contentModified: nil, services: services,
                progress: progress, completion: completion)
        }
        if ref.isPackage {
            return modifyPackageContents(
                path: path, contents: newContents, baseDigest: baseSha, services: services,
                progress: progress, completion: completion)
        }
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
                    let materialized = await services.returnedMaterializedFlag(for: path)
                    completion.value(
                        FileProviderItem(node: .file(path: path, entry: entry), materialized: materialized),
                        [], false, nil)
                case .unchanged(let entry):
                    // base 不明（rebind 直後等）× ツリー現行と同一内容 = 何も書いていない。
                    // イベントなしで identity 返却のみ（completeCreate の .unchanged と同じ扱い）。
                    AppLogger.fileProvider.notice("modifyItem: unchanged (idempotent replay): \(path, privacy: .private)")
                    let materialized = await services.returnedMaterializedFlag(for: path)
                    completion.value(
                        FileProviderItem(node: .file(path: path, entry: entry), materialized: materialized),
                        [], false, nil)
                case .conflict(let remote, let copyPath, _):
                    // 正規パスはリモート版が勝つ（FSEvents 側と対称）。shouldFetchContent=true で
                    // システムにリモート内容を取り直させる。ローカル編集は conflict copy として
                    // 自世代に反映済み → 直後の enumerateChanges で新 item として出現する。
                    AppLogger.fileProvider.notice("modifyItem: upload conflict — local edit preserved as copy: \(copyPath, privacy: .private)")
                    await services.events.append(
                        type: .conflict, path: path,
                        message: "Upload conflict — local edit preserved as copy → \(copyPath)")
                    // 内容はこれから取り直すので台帳に記録しない（伝え済みの状態のまま返す）。
                    let materialized = await services.toldMaterializedFlag(for: path)
                    completion.value(
                        FileProviderItem(node: .file(path: path, entry: remote), materialized: materialized),
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

    /// 届いた中身がフォルダか（lstat = 最後の要素のリンクは追わない）。取れなければ nil（従来の経路へ）。
    private static func isDirectoryNoFollow(_ url: URL) -> Bool? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }

    /// modifyItem の書類の形式の切り替え（#140）。パッケージ → 単一ファイル（`toPackage: false`）は
    /// `ExtensionWriter.replacePackageWithFile`、単一ファイル → パッケージは `replaceFileWithPackage`。
    /// 返す item は新しい形式の id（`f:` ⇄ `k:`）= 改名と同じ id の付け替え。
    private func modifyFormatChange(
        path: String, contents: URL, toPackage: Bool, baseVersion: String?, contentModified: Date?,
        services: ExtensionServices, progress: Progress,
        completion: UncheckedSendableBox<(NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void>
    ) -> Progress {
        let boxedURL = UncheckedSendableBox(value: contents)
        let task = Task {
            defer { progress.completedUnitCount = progress.totalUnitCount }
            do {
                let outcome = toPackage
                    ? try await services.writer.replaceFileWithPackage(
                        path: path, contentsURL: boxedURL.value, baseSha: baseVersion)
                    : try await services.writer.replacePackageWithFile(
                        path: path, contentsURL: boxedURL.value, baseDigest: baseVersion,
                        contentModified: contentModified)
                switch outcome {
                case .changed(let node):
                    await services.events.append(
                        type: .upload, path: path,
                        message: toPackage ? "Converted to package (\(node.memberCount) files)" : "Converted to single file")
                    await services.virtualDirs.removeAncestors(of: path)
                    let materialized = await services.returnedMaterializedFlag(for: path)
                    completion.value(FileProviderItem(node: node, materialized: materialized), [], false, nil)
                case .conflict(let remote, let copyPath):
                    AppLogger.fileProvider.notice("modifyItem(format change): upload conflict — local edit preserved as copy: \(copyPath, privacy: .private)")
                    await services.events.append(
                        type: .conflict, path: path,
                        message: "Upload conflict — local edit preserved as copy → \(copyPath)")
                    guard let remote, !remote.isDirectory else {
                        // 正規パスに今は書類が無い。一時エラーで再試行させ、次の差分配信に任せる
                        // （ローカルの内容は競合コピーに上がっている）。
                        completion.value(nil, [], false, Self.moveConflictError())
                        return
                    }
                    let materialized = await services.toldMaterializedFlag(for: path)
                    completion.value(FileProviderItem(node: remote, materialized: materialized), [], true, nil)
                case .packageNotWritable(let written):
                    switch written {
                    case .excluded(let reason):
                        // 単一ファイルが除外の条件に当たるパッケージになった = 編集で除外になったパッケージと
                        // 同じく、続く後片付けの deleteItem で旧いファイルを S3 から外す。
                        await Self.recordPackageExclusion(reason, path: path, services: services)
                        await services.exclusionCleanups.add(path)
                        completion.value(nil, [], false, NSFileProviderError(.excludedFromSync))
                    case .empty:
                        AppLogger.fileProvider.notice("modifyItem(format change): nothing to sync (excluded; cleanup reserved): \(path, privacy: .private)")
                        await services.exclusionCleanups.add(path)
                        completion.value(nil, [], false, NSFileProviderError(.excludedFromSync))
                    default:
                        // 同じパスがフォルダ = その書類はもう無い
                        completion.value(nil, [], false, NSFileProviderError(.noSuchItem))
                    }
                }
            } catch {
                AppLogger.fileProvider.error("modifyItem(format change) failed: \(String(describing: error), privacy: .private)")
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

    /// modifyItem の .contents のパッケージ分岐（#140）。3-way のベースは baseVersion の digest。
    ///
    /// 編集でシンボリックリンク等が入った・上限を超えた・中身が空になったパッケージは、改名で除外名に
    /// なったファイルと同じく `ExcludedFromSync` を返し、後片付けの deleteItem を予約で受理する
    /// （S3 の旧版はバックアップから外れる = 通知する。ローカルの実体は残る）。
    private func modifyPackageContents(
        path: String, contents: URL, baseDigest: String?, services: ExtensionServices,
        progress: Progress,
        completion: UncheckedSendableBox<(NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void>
    ) -> Progress {
        let boxedURL = UncheckedSendableBox(value: contents)
        let task = Task {
            defer { progress.completedUnitCount = progress.totalUnitCount }
            do {
                let outcome = try await services.writer.writePackage(
                    path: path, contentsURL: boxedURL.value, baseDigest: baseDigest)
                switch outcome {
                case .written(let node), .unchanged(let node):
                    if case .written = outcome {
                        await services.events.append(
                            type: .upload, path: path, message: "Uploaded package (\(node.memberCount) files)")
                    } else {
                        AppLogger.fileProvider.notice("modifyItem(package): unchanged (idempotent replay): \(path, privacy: .private)")
                    }
                    let materialized = await services.returnedMaterializedFlag(for: path)
                    completion.value(FileProviderItem(node: node, materialized: materialized), [], false, nil)
                case .conflict(let copyPath, _):
                    // 正規パスはリモートが勝つ（ファイルと同じ）。リモートの中身を取り直させる。
                    AppLogger.fileProvider.notice("modifyItem(package): upload conflict — local edit preserved as copy: \(copyPath, privacy: .private)")
                    await services.events.append(
                        type: .conflict, path: path,
                        message: "Upload conflict — local edit preserved as copy → \(copyPath)")
                    guard let remote = try await services.cache.current().tree.node(at: path), remote.isPackage else {
                        // リモートの正規パスが今はパッケージでない（さらに消えた等）。一時エラーで再試行させ、
                        // 次の差分配信に任せる（ローカルの中身は競合コピーに上がっている）。
                        completion.value(nil, [], false, Self.moveConflictError())
                        return
                    }
                    let materialized = await services.toldMaterializedFlag(for: path)
                    completion.value(FileProviderItem(node: remote, materialized: materialized), [], true, nil)
                case .excluded, .empty:
                    if case .excluded(let reason) = outcome {
                        await Self.recordPackageExclusion(reason, path: path, services: services)
                    } else {
                        AppLogger.fileProvider.notice("modifyItem(package): nothing to sync (excluded; cleanup reserved): \(path, privacy: .private)")
                    }
                    await services.exclusionCleanups.add(path)
                    completion.value(nil, [], false, NSFileProviderError(.excludedFromSync))
                case .kindCollision:
                    // id は k: なのに同じパスがフォルダ = そのパッケージはもう無い
                    completion.value(nil, [], false, NSFileProviderError(.noSuchItem))
                }
            } catch {
                AppLogger.fileProvider.error("modifyItem(package) failed: \(String(describing: error), privacy: .private)")
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
    /// - dir move の除外判定は**新 dir パス単位のみ**（機密網 + ユーザパターンの dir 一致。
    ///   効いている層に `!` があれば除外しない = #124）。
    ///   子ごとの新 path パターン一致は意図的に適用しない — FP では旧 id の削除配信が
    ///   ローカル実体も消すため、「ローカル温存で非同期」を per-child に再現できない
    ///   （dir 単位の ExcludedFromSync なら実体温存で全体が同期外 = 損失ゼロ）。docs/08 参照。
    /// - `.sourceChanged`（リモート先行）は一時エラー返却 = 新旧両存のまま。リモート変化が
    ///   届いて baseVersion が追いつくと再試行の move が「進んだ後の内容」で自己回復する。
    private func handleMove(
        item: NSFileProviderItem,
        ref: TideItemRef,
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
        // 除外したときの通知に出す新しい名前（検証できない名前もそのまま・表示専用・#147）
        let newDisplayPath = FileProviderWritePolicy.displayPath(parentPath: newParentPath, filename: item.filename)
        // 仮想フォルダを返すときの日時（Issue #144）。改名の modifyItem では item に日時が入って
        // いない（`changedFields` が名前だけのとき・実機）ので、前に返した版（baseVersion の
        // metadataVersion = `dir-<日時>`）から取り出す。日時なしで返すとシステムが 1970 を書く。
        let virtualDirMtime = (item.contentModificationDate ?? nil)
            ?? FileProviderWritePolicy.directoryMtime(fromMetadataVersion: version.metadataVersion)
        guard validNewPath != oldPath else {
            // 実質 no-op（同一 path への「移動」）。この分岐は実際に踏める — Swift の
            // `String ==` は正準等価（NFC/NFD 同一視）のため、正規化差だけの rename が該当する。
            // **`.contents` が同時に立っている複合 modifyItem はここで握りつぶさない**
            //（PR #60 レビュー #4: 全フィールド消化で返すと新内容が未アップロードのまま
            // 「同期済み」になる無エラー乖離）— rename は no-op とし、内容は通常の
            // modifyFileContents 経路（modifyItem の .contents 分岐と同じ帰結写像）で処理する。
            if ref.isPackage, changedFields.contains(.contents), let newContents {
                // パッケージの内容は writePackage へ（ファイルの modifyFileContents に流さない・#140）
                return modifyPackageContents(
                    path: oldPath, contents: newContents,
                    baseDigest: FileProviderWritePolicy.baseSha(
                        contentVersion: version.contentVersion, metadataVersion: version.metadataVersion),
                    services: services, progress: progress, completion: completion)
            }
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
                            let materialized = await services.returnedMaterializedFlag(for: oldPath)
                            completion.value(
                                FileProviderItem(
                                    node: .file(path: oldPath, entry: entry), materialized: materialized),
                                [], false, nil)
                        case .unchanged(let entry):
                            // base 不明 × 同一内容の冪等リプレイ（イベントなし・identity 返却のみ）。
                            AppLogger.fileProvider.notice("modifyItem(move noop): unchanged (idempotent replay): \(oldPath, privacy: .private)")
                            let materialized = await services.returnedMaterializedFlag(for: oldPath)
                            completion.value(
                                FileProviderItem(
                                    node: .file(path: oldPath, entry: entry), materialized: materialized),
                                [], false, nil)
                        case .conflict(let remote, let copyPath, _):
                            AppLogger.fileProvider.notice("modifyItem(move noop): upload conflict — local edit preserved as copy: \(copyPath, privacy: .private)")
                            await services.events.append(
                                type: .conflict, path: oldPath,
                                message: "Upload conflict — local edit preserved as copy → \(copyPath)")
                            // 内容はこれから取り直すので台帳に記録しない（上の modifyItem 競合と同じ）。
                            let materialized = await services.toldMaterializedFlag(for: oldPath)
                            completion.value(
                                FileProviderItem(
                                    node: .file(path: oldPath, entry: remote), materialized: materialized),
                                [], true, nil)
                        }
                        return
                    }
                    let tree = try await services.cache.current().tree
                    if let node = tree.node(at: oldPath) {
                        // 実体化バッジ（Issue #65）: 伝え済み（報告済み + 返却分）基準のフラグを維持（固着防止）。
                        let told = await services.toldMaterialized()
                        completion.value(
                            BadgeFlags(tree: tree, told: told).item(node), [], false, nil)
                    } else if ref.isPackage {
                        // パッケージに仮想の受け皿は無い（#140）= もう無い
                        completion.value(nil, [], false, NSFileProviderError(.noSuchItem))
                    } else {
                        // 仮想フォルダ: 日時を付けて返す（Issue #144: nil は 1970 になる）
                        completion.value(
                            FileProviderItem(node: .directory(path: oldPath, mtime: virtualDirMtime)),
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
        // 改名と同時に内容も変わった move（複合）で旧 path を消してよいかのベース（PR #152 レビュー指摘 7）
        let moveBase = FileProviderWritePolicy.baseSha(
            contentVersion: version.contentVersion, metadataVersion: version.metadataVersion)
        let task = Task {
            defer { progress.completedUnitCount = progress.totalUnitCount }
            do {
                let current = try await services.cache.current()

                if isDirectory {
                    let prefix = oldPath + "/"
                    // 配下のパッケージは中身に開いて一緒に動かす（#140・落とすと旧の場所に残る）
                    let children = current.tree.trackedFiles(under: oldPath).map {
                        (from: $0.path, entry: $0.entry)
                    }
                    // 除外判定: 検証不能な新名 / 機密網（component 一致）/ ユーザパターンの
                    // dir 一致（`<dir>/` 評価）→ subtree ごと同期対象外（実体はローカル温存）。
                    // 効いている層に否定（`!`）があれば除外せず改名を受理する（#124・判定は
                    // `IgnoreDecision.shouldExcludeDirectoryOnRename`）。機密網はツリーを引かずに即決。
                    let excluded: Bool
                    if let newPath = validNewPath {
                        if HardcodedIgnoreRules.shouldIgnore(relativePath: newPath) {
                            excluded = true
                        } else {
                            let layered = try await services.ignore.layeredIgnore(
                                tree: current.tree, anchor: current.anchor)
                            excluded = IgnoreDecision.shouldExcludeDirectoryOnRename(
                                relativePath: newPath, matcher: layered)
                        }
                    } else {
                        excluded = true
                    }
                    if excluded {
                        // ExcludedFromSync = ローカルで改名成立・subtree ごと同期対象外。
                        // **マニフェストはここでは触らない** — SDK は除外時に「内容をダウンロード
                        // してから deleteItem を発行」する契約で、先に entry を消すと dataless の
                        // 子が materialize できない殻になる（5-4 実機で確定）。後追い deleteItem
                        //（dir 再帰）は子のベースをツリー現行 sha で取るため、受理のための予約は不要 =
                        // そのまま受理される（下の予約はバッジの凍結用）。
                        AppLogger.fileProvider.notice("modifyItem(move): dir excluded (excludedFromSync; cleanup via system deleteItem): \(oldPath, privacy: .private)")
                        // 配下に追跡中のファイルがあれば、後片付けで S3 から外れる = 通知する（#147）。
                        // 中身が仮想フォルダだけなら S3 に影響しないので通知しない。
                        await services.events.append(
                            type: .info, path: oldPath,
                            message: "Excluded from sync by rename (kept local)", details: newDisplayPath,
                            notice: children.isEmpty ? nil : .renamedFolderExcluded)
                        await services.virtualDirs.removeSubtree(at: oldPath)
                        // 後片付けの deleteItem(dir) までは旧フォルダ配下のバッジを伝え済みのまま
                        // 凍結する（Issue #138・PR #142 レビュー指摘 2: 配下の旧 item を版を変えて
                        // 再通知すると、ファイルの改名と同じく後片付けが来なくなりうる）。予約は
                        // 旧フォルダの path 1 件（凍結は祖先一致 = `MaterializedBadge.isFrozen`）。
                        // ファイルの後片付け予約（受理根拠）とは別の集合に積む（PR #143 レビュー指摘 1）。
                        // 同じ名前のフォルダが作り直されても外さない — 旧フォルダの後片付けの前に
                        // 凍結が解けると同じ詰まりが起こりうる（同 指摘 2）。
                        await services.dirCleanupFreezes.add(oldPath)
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
                        // 日時を付けて返す（Issue #144: nil は 1970 になる）
                        completion.value(
                            FileProviderItem(node: .directory(path: newPath, mtime: virtualDirMtime)),
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
                    case .moved, .movedKeepingSource:
                        AppLogger.fileProvider.notice("modifyItem(move): dir moved (\(descendants.count) files): -> \(newPath, privacy: .private)")
                        await services.events.append(
                            type: .move, path: oldPath,
                            message: "Moved → \(newPath) (\(descendants.count) files)")
                        // 実体化バッジ（Issue #65）: move は内容を動かさないので実体化状態は不変。
                        // 返却 dir のチェックは旧 path（移動前ツリー）の集計を引き継ぎ、報告済み
                        // レジストリは subtree ごと新 path へ追従させる（追従しないと移動直後の
                        // 差分が配下全件の再点灯として再送されるチャーンになる）。
                        let told = await services.toldMaterialized()
                        let wasChecked = BadgeFlags(tree: current.tree, told: told)
                            .isOn(.directory(path: oldPath, mtime: oldMtime))
                        await services.materializedReported.renameSubtree(from: oldPath, to: newPath)
                        // 配下の仮想サブフォルダ（空 dir）のレジストリエントリも新 path へ追従
                        await services.virtualDirs.renameSubtree(from: oldPath, to: newPath)
                        completion.value(
                            FileProviderItem(
                                node: .directory(path: newPath, mtime: oldMtime),
                                materialized: wasChecked),
                            [], false, nil)
                        // 版スタンプの治癒は item 単位（ファイルとパッケージ）で頼む（#140: パッケージの
                        // 中身は item ではない）
                        let leaves = current.tree.leaves(under: oldPath)
                        Self.scheduleVersionRestamp(
                            moves: leaves.map {
                                (from: $0.path, to: newPath + "/" + $0.path.dropFirst(prefix.count))
                            },
                            packages: Set(leaves.filter(\.isPackage).map {
                                newPath + "/" + $0.path.dropFirst(prefix.count)
                            }),
                            services: services)
                    case .destinationOccupied:
                        completion.value(nil, [], false, NSFileProviderError(.filenameCollision))
                    case .sourceChanged(let path, _):
                        AppLogger.fileProvider.notice("modifyItem(move): source changed under dir (retry later): \(path, privacy: .private)")
                        completion.value(nil, [], false, Self.moveConflictError())
                    }
                    return
                }

                if ref.isPackage {
                    try await Self.movePackage(
                        from: oldPath, to: validNewPath, newDisplayPath: newDisplayPath,
                        contents: hasNewContents ? boxedURL.value : nil, baseDigest: moveBase,
                        current: current, services: services, completion: completion)
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
                    // 追跡中なら後片付けで S3 から外れる = 通知する（#147）
                    await services.events.append(
                        type: .info, path: oldPath,
                        message: "Excluded from sync by rename (kept local)", details: newDisplayPath,
                        notice: current.tree.node(at: oldPath) == nil ? nil : .renamedFileExcluded)
                    completion.value(nil, [], false, NSFileProviderError(.excludedFromSync))
                    return
                }
                let newPath = validNewPath!  // excluded が nil ケースを吸収済み
                if let node = current.tree.node(at: newPath), node.isDirectory || node.isPackage {
                    // kind 衝突（新 path にマニフェスト dir・パッケージが実在）→ 名前バウンス。パッケージの
                    // 上に単一ファイルの entry を書くと、ツリーでパッケージが勝って誰にも見えないまま
                    // バックアップから外れる（PR #152 レビュー指摘 3）
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
                    baseSha: moveBase, contentModified: contentModified
                )
                let movedEntry: ManifestFileEntry?
                let keptSource: Bool
                switch outcome {
                case .moved(let newEntry):
                    (movedEntry, keptSource) = (newEntry, false)
                case .movedKeepingSource(let newEntry):
                    (movedEntry, keptSource) = (newEntry, true)
                case .destinationOccupied, .sourceChanged:
                    (movedEntry, keptSource) = (nil, false)
                }
                switch outcome {
                case .moved, .movedKeepingSource:
                    // 返却 item は新 id（rebind）。newEntry は単一 move では必ず非 nil。
                    // 実体化バッジ（Issue #65）: move は内容を動かさない = 実体化状態は旧 path を
                    // 引き継ぎ、報告済みレジストリも新 path へ追従（チャーン防止）。
                    // 旧 path を残したとき（他の端末の版）は、次の差分配信で別の item として現れる。
                    let entry = movedEntry ?? entry
                    await services.events.append(
                        type: .move, path: oldPath,
                        message: keptSource
                            ? "Moved → \(newPath) (with changes; original kept: changed on another device)"
                            : "Moved → \(newPath)")
                    // live と返却分の台帳も追従させる（Issue #138: 追従しないと次の観測までの
                    // 差分配信が移動先を未実体化として再送し、版が変わる）。
                    let told = await services.toldMaterialized()
                    let wasMaterialized = told.reported.contains(oldPath)
                        || told.pendingReturned.contains(oldPath)
                    await services.followMaterializedFileMove(from: oldPath, to: newPath)
                    completion.value(
                        FileProviderItem(
                            node: .file(path: newPath, entry: entry),
                            materialized: wasMaterialized),
                        [], false, nil)
                    Self.scheduleVersionRestamp(
                        moves: [(from: oldPath, to: newPath)], packages: [], services: services)
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

    /// パッケージの改名 / 移動（#140）。除外の判定はファイルと同じ（パッケージのパスに当てる）。
    /// 中身はフォルダの move と同じ `moveDirectory`（copyObject → 全 add → 全 remove）で動かす。
    ///
    /// 改名と同時に内容も変わったとき（`contents` あり）は、新しいパスへ新規作成として書いて
    /// （`writePackage(baseDigest: nil)`）から旧の中身を消す。途中で止まっても新旧両方が残る側に倒れ、
    /// 再試行では新しいパスが同じ中身 = 書かずに旧の削除へ進む。旧の中身を消すのは、システムが最後に
    /// 見た版（`baseDigest`）が旧パスの今の版と一致するときだけ — 合わない・ベースが無い・消す段で
    /// 他の端末の更新に気づいたときは、旧パスを他の端末の版のまま残す（ファイルの複合 move と同じ・
    /// PR #152 レビュー指摘 7）。
    private static func movePackage(
        from oldPath: String, to validNewPath: String?, newDisplayPath: String, contents: URL?,
        baseDigest: String?,
        current: ManifestGenerationCache.Current, services: ExtensionServices,
        completion: UncheckedSendableBox<(NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void>
    ) async throws {
        let oldNode = current.tree.node(at: oldPath)
        let excluded: Bool
        if let newPath = validNewPath {
            let layered = try await services.ignore.layeredIgnore(
                tree: current.tree, anchor: current.anchor)
            excluded = IgnoreDecision.shouldSkip(
                relativePath: newPath, isAlreadyTracked: current.tree.node(at: newPath) != nil,
                matcher: layered)
        } else {
            excluded = true
        }
        if excluded {
            // ファイルの除外名への改名と同じ: マニフェストは触らず、後片付けの deleteItem を予約で受理する。
            await services.exclusionCleanups.add(oldPath)
            AppLogger.fileProvider.notice("modifyItem(move package): excluded new name (excludedFromSync; cleanup reserved): \(oldPath, privacy: .private)")
            await services.events.append(
                type: .info, path: oldPath,
                message: "Excluded from sync by rename (kept local)", details: newDisplayPath,
                notice: oldNode == nil ? nil : .renamedFileExcluded)
            completion.value(nil, [], false, NSFileProviderError(.excludedFromSync))
            return
        }
        let newPath = validNewPath!  // excluded が nil ケースを吸収済み
        guard case .package(_, let members, let oldDigest, _)? = oldNode else {
            completion.value(nil, [], false, NSFileProviderError(.noSuchItem))
            return
        }
        let told = await services.toldMaterialized()
        let wasMaterialized = told.reported.contains(oldPath) || told.pendingReturned.contains(oldPath)

        if let contents {
            let written: ManifestTree.Node
            switch try await services.writer.writePackage(path: newPath, contentsURL: contents, baseDigest: nil) {
            case .written(let node), .unchanged(let node):
                written = node
            case .conflict, .kindCollision:
                // 新しいパスに別の中身・フォルダがある（競合コピーは上がっている）= 名前をずらしてもらう
                completion.value(nil, [], false, NSFileProviderError(.filenameCollision))
                return
            case .excluded(let reason):
                await recordPackageExclusion(reason, path: oldPath, services: services)
                await services.exclusionCleanups.add(oldPath)
                completion.value(nil, [], false, NSFileProviderError(.excludedFromSync))
                return
            case .empty:
                await services.exclusionCleanups.add(oldPath)
                completion.value(nil, [], false, NSFileProviderError(.excludedFromSync))
                return
            }
            var keptSource = !FileProviderWritePolicy.moveMayRemoveSource(baseSha: baseDigest, current: oldDigest)
            if !keptSource {
                var expected: [String: String] = [:]
                for (relative, entry) in members { expected[oldPath + "/" + relative] = entry.sha256 }
                switch try await services.writer.deleteDirectory(expecting: expected) {
                case .removed:
                    break
                case .removedIndexStale(_, let detail):
                    throw SyncError.indexUpdateFailedAfterCommit(detail)
                case .rejected(let path, _):
                    // 旧パスの中身を他の端末が書き換えていた = 旧パスは残す（新しいパスは書き済み）
                    AppLogger.fileProvider.notice("modifyItem(move package): source changed while moving; keeping it: \(path, privacy: .private)")
                    keptSource = true
                }
            } else {
                AppLogger.fileProvider.notice("modifyItem(move package): source changed since base; keeping it: \(oldPath, privacy: .private)")
            }
            await services.events.append(
                type: .move, path: oldPath,
                message: keptSource
                    ? "Moved → \(newPath) (with changes; original kept: changed on another device)"
                    : "Moved → \(newPath) (with changes)")
            await services.followMaterializedFileMove(from: oldPath, to: newPath)
            let materialized = await services.returnedMaterializedFlag(for: newPath)
            completion.value(FileProviderItem(node: written, materialized: materialized), [], false, nil)
            return
        }

        guard current.tree.node(at: newPath) == nil else {
            completion.value(nil, [], false, NSFileProviderError(.filenameCollision))
            return
        }
        let descendants = members.map {
            (from: oldPath + "/" + $0.key, to: newPath + "/" + $0.key, entry: $0.value)
        }
        switch try await services.writer.moveDirectory(descendants: descendants) {
        case .moved, .movedKeepingSource:
            await services.events.append(
                type: .move, path: oldPath, message: "Moved → \(newPath)")
            // 実体化状態は旧 path を引き継ぐ（ファイルの move と同じ）
            await services.followMaterializedFileMove(from: oldPath, to: newPath)
            completion.value(
                FileProviderItem(
                    node: ManifestTree.packageNode(path: newPath, members: members),
                    materialized: wasMaterialized),
                [], false, nil)
            scheduleVersionRestamp(
                moves: [(from: oldPath, to: newPath)], packages: [newPath], services: services)
        case .destinationOccupied:
            completion.value(nil, [], false, NSFileProviderError(.filenameCollision))
        case .sourceChanged(let path, _):
            AppLogger.fileProvider.notice("modifyItem(move package): source changed (retry later): \(path, privacy: .private)")
            completion.value(nil, [], false, moveConflictError())
        }
    }

    /// 版スタンプ自動治癒（Issue #93）の待ち時間。初回猶予 = ダエモンが completion 返却
    /// （rebind）を ingest するまでの経験的マージン、再試行待ち = ingest 遅延時の一度きりの
    /// 追い猶予（値は実機受け入れで妥当性を確認する）。
    private static let restampInitialDelay: Duration = .seconds(1)
    private static let restampRetryDelay: Duration = .seconds(2)

    /// rename/reparent 直後の版スタンプ自動治癒（Issue #93）。fileproviderd は rebind
    /// （modifyItem 返却 item での id 変更）時にローカル内容の版スタンプを再刻印しない
    /// （OS 側挙動・実機確定 2026-07-31）ため、settle 済みファイルの move 後は
    /// `isMostRecentVersionDownloaded = 0` が固着し、実体化バッジとクラウドアイコンが併存する
    /// （実害は表示のみ）。move 完了直後に拡張自身が `reimportItems(below:)` を要求すると、
    /// ダエモンがディスク上表現を再スキャン → createItem(mayAlreadyExist) の問い直しに拡張が
    /// 同一 sha ファストパス（`.unchanged`）で生 sha 版 item を返し、帳簿が再構築されて治る
    /// （実機実証 2026-08-25・S3 非接触。`requestDownloadForItem` は実体化済み item に no-op で
    /// 不成立 — `ExtensionServices.requestReimport` のコメント参照）。
    ///
    /// - 対象は**実体化済みファイルのみ**（`FileProviderWritePolicy.moveRestampTargets`）:
    ///   dataless は症状が可視化されず（クラウドアイコンは dataless の正しい表示）、次の
    ///   materialize（fetchContents）で自然に再刻印されるため治癒不要。
    ///   ゲート集合はダエモン live 問い合わせを正とし、失敗時のみ報告済みレジストリへ
    ///   フォールバック（バッジと同じ「live 優先・reported は近似」の姿勢）。
    /// - completion 返却（= rebind の acknowledge）後に独立で走らせる detached Task —
    ///   modifyItem の progress cancellation に巻き込ませない（治癒は move 成立後の独立作業）。
    /// - `noSuchItem`（rebind ingest 前に撃った race / 直前 import 未了）は該当分を集め、
    ///   ingest 猶予を**全件共有で一度だけ**待ってからまとめて再試行（per-file 直列待ちだと
    ///   dir move N 件でワーストケース N×2 秒に伸びる。PR #113 レビュー #2）。それでも失敗なら
    ///   諦める（「次の編集 or 開いて保存で自然治癒」の従来挙動に戻るだけ・安全側）。
    /// - Parameter packages: 移動先のうちパッケージのパス（再取り込みを `k:` の id で頼む・#140）。
    private static func scheduleVersionRestamp(
        moves: [(from: String, to: String)], packages: Set<String>, services: ExtensionServices
    ) {
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: restampInitialDelay)
            let gate: Set<String>
            if let live = await services.queryMaterializedFilePaths() {
                gate = live
            } else {
                gate = await services.materializedReported.snapshot()
            }
            let targets = FileProviderWritePolicy.moveRestampTargets(
                moves: moves, materialized: gate)
            guard !targets.isEmpty else {
                // 実体化済みの対象なし = 治癒不要（dataless に症状は出ない）。スキップも痕跡を
                // 残す — 無音だと「発火しない」の切り分けが log からできない（2026-08-25 実踏:
                // dir move の配下実体化消失でここに来たケースの診断に手間取った）。
                AppLogger.fileProvider.notice("move restamp: no materialized targets among \(moves.count) moved file(s) (skip)")
                return
            }
            AppLogger.fileProvider.notice("move restamp: requesting reimport for \(targets.count) file(s)")
            await services.events.append(
                type: .info, path: targets.count == 1 ? targets[0] : nil,
                message: targets.count == 1
                    ? "Refreshing cloud status after move"
                    : "Refreshing cloud status after move (\(targets.count) files)")
            func logOutcome(_ error: Error?, path: String) {
                if let error {
                    AppLogger.fileProvider.error("move restamp failed (self-heals on next edit): \(String(describing: error), privacy: .private) path=\(path, privacy: .private)")
                } else {
                    // acknowledge 成功の痕跡（実機診断用・#93）: これが出ているのに fetchContents が
                    // 走らない場合、要求はダエモンへ届いた上で握りつぶされている（呼出し側の問題でない）。
                    AppLogger.fileProvider.notice("move restamp: acknowledged: \(path, privacy: .private)")
                }
            }
            var retryTargets: [String] = []
            for path in targets {
                let error = await services.requestReimport(path, packages.contains(path) ? .package : .file)
                if let fpError = error as? NSFileProviderError, fpError.code == .noSuchItem {
                    retryTargets.append(path)
                } else {
                    logOutcome(error, path: path)
                }
            }
            if !retryTargets.isEmpty {
                // 待ちの意味は「ダエモンの ingest 完了待ち」なので全件共有の一度きりで足りる。
                try? await Task.sleep(for: restampRetryDelay)
                for path in retryTargets {
                    logOutcome(
                        await services.requestReimport(path, packages.contains(path) ? .package : .file),
                        path: path)
                }
            }
        }
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
                    // 配下のパッケージは中身に開いて一緒に消す（#140）
                    var expected: [String: String] = [:]
                    for (p, entry) in current.tree.trackedFiles(under: dirPath) {
                        expected[p] = entry.sha256
                    }
                    // フォルダ単位除外の予約（#120 レビュー B1）: 自身か祖先に予約があれば、
                    // これは除外の後始末 = 追跡数に関わらず S3 非接触で完了させる。
                    var hasHold = false
                    for candidate in FileProviderWritePolicy.pathAndAncestors(dirPath) {
                        if await services.dirExclusionHolds.contains(candidate) {
                            hasHold = true
                            break
                        }
                    }
                    switch FileProviderWritePolicy.directoryDeletePlan(
                        trackedCount: expected.count, hasExclusionHold: hasHold,
                        recursive: recursive) {
                    case .localOnly:
                        // 追跡ファイルなし = ローカル仮想フォルダ / 既に空・消滅済み、または
                        // フォルダ単位除外の後始末。S3 非接触でローカル削除だけ成立させる（冪等成功）。
                        if hasHold {
                            if expected.isEmpty {
                                AppLogger.fileProvider.notice("deleteItem(dir): exclusion cleanup completed (S3 untouched): \(dirPath, privacy: .private)")
                            } else {
                                AppLogger.fileProvider.notice("deleteItem(dir): exclusion cleanup kept \(expected.count) tracked files on S3: \(dirPath, privacy: .private)")
                            }
                        }
                        await services.virtualDirs.removeSubtree(at: dirPath)
                        await services.dirExclusionHolds.removeSubtree(at: dirPath)
                        await services.exclusionCleanups.removeSubtree(at: dirPath)
                        await services.dirCleanupFreezes.removeSubtree(at: dirPath)
                        // 実体化バッジ: 消えた subtree を報告済み・live・台帳から外す（PR #142
                        // レビュー指摘 9）。
                        await services.followMaterializedRemoval(at: dirPath)
                        dirCompletion.value(nil)
                        return
                    case .notEmpty:
                        // 非再帰削除で中身がある → SDK 契約どおり DirectoryNotEmpty
                        //（システムが dir を最新メタデータから再作成する）。
                        // フォルダの凍結予約（Issue #138）も外す（下の `.rejected` と同じ理由）。
                        await services.releaseDirCleanupFreeze(at: dirPath)
                        dirCompletion.value(NSFileProviderError(.directoryNotEmpty))
                        return
                    case .deleteRemote:
                        break
                    }
                    switch try await services.writer.deleteDirectory(expecting: expected) {
                    case .removed(let count):
                        AppLogger.fileProvider.notice("deleteItem(dir): removed \(count) files under \(dirPath, privacy: .private)")
                        await services.events.append(
                            type: .delete, path: dirPath, message: "Deleted folder (\(count) files)")
                        await services.virtualDirs.removeSubtree(at: dirPath)
                        await services.dirExclusionHolds.removeSubtree(at: dirPath)
                        // フォルダを除外名へ改名したときの後片付け予約・凍結予約（Issue #138）を外す。
                        await services.exclusionCleanups.removeSubtree(at: dirPath)
                        await services.dirCleanupFreezes.removeSubtree(at: dirPath)
                        // 実体化バッジ（Issue #65）: 消えた subtree の報告済みエントリも掃除
                        await services.followMaterializedRemoval(at: dirPath)
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
                        // フォルダの凍結予約（Issue #138）は外す — システムは旧フォルダをリモートの内容で
                        // 作り直し（createItem は来ない）、残すとその配下のバッジが凍結されたままになる。
                        // 凍結予約は削除の受理判定に使わないので、外しても判定は変わらない（ファイルの
                        // 後片付け予約は別の集合 = 再送された後片付けの受理根拠のまま残る）。
                        await services.releaseDirCleanupFreeze(at: dirPath)
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
        if ref.isPackage {
            return deletePackage(
                path: ref.path, baseDigest: baseSha, services: services,
                progress: progress, completionHandler: completionHandler)
        }
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
                    await services.followMaterializedRemoval(at: ref.path)
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
                    // 実体化バッジ（Issue #65）: 添える最新 item も伝え済み（報告済み + 返却分）
                    // 基準のフラグを維持
                    let told = await services.toldMaterialized()
                    let isMaterialized = told.reported.contains(ref.path)
                        || told.pendingReturned.contains(ref.path)
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

    /// パッケージの削除（#140）。ベースは baseVersion の digest（ツリーの今の版と一致したときだけ消す・
    /// 合わなければ最新の item を添えて拒否 = システムが戻す）。除外の後片付け（予約あり・ベースが
    /// digest の形でない）はツリーの今の版をベースに読み替える（ファイルと同じ）。中身の除去は
    /// フォルダの再帰削除と同じ `deleteDirectory`（中身ごとにツリーの sha で RMW ガード）。
    /// そのパスがもうパッケージでない（消えた・ファイルで保存し直された）ときは、消すものが無い = 成功。
    private func deletePackage(
        path: String, baseDigest: String?, services: ExtensionServices,
        progress: Progress, completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let completion = UncheckedSendableBox(value: completionHandler)
        let task = Task {
            defer { progress.completedUnitCount = progress.totalUnitCount }
            func forgetLocalState() async {
                await services.exclusionCleanups.removeSubtree(at: path)
                await services.followMaterializedRemoval(at: path)
            }
            do {
                let tree = try await services.cache.current().tree
                guard case .package(_, let members, let digest, _)? = tree.node(at: path) else {
                    await forgetLocalState()
                    completion.value(nil)
                    return
                }
                let isCleanup = baseDigest == nil ? await services.exclusionCleanups.contains(path) : false
                guard baseDigest == digest || isCleanup else {
                    let reason = baseDigest == nil ? "base unknown" : "remote changed since base"
                    AppLogger.fileProvider.notice("deleteItem(package): rejected (\(reason, privacy: .public)): \(path, privacy: .private)")
                    await services.events.append(
                        type: .info, path: path, message: "Delete rejected (\(reason))")
                    let materialized = await services.toldMaterializedFlag(for: path)
                    completion.value(NSError.fileProviderErrorForRejectedDeletion(
                        of: FileProviderItem(node: tree.node(at: path)!, materialized: materialized)))
                    return
                }
                var expected: [String: String] = [:]
                for (relative, entry) in members { expected[path + "/" + relative] = entry.sha256 }
                switch try await services.writer.deleteDirectory(expecting: expected) {
                case .removed(let count):
                    await services.events.append(
                        type: .delete, path: path, message: "Deleted package (\(count) files)")
                    if isCleanup {
                        AppLogger.fileProvider.notice("deleteItem(package): exclusion cleanup completed: \(path, privacy: .private)")
                    }
                    await forgetLocalState()
                    completion.value(nil)
                case .removedIndexStale(let count, let detail):
                    AppLogger.fileProvider.error("deleteItem(package): partial completion (index update pending, \(count) files removed): \(path, privacy: .private): \(detail, privacy: .private)")
                    await services.events.append(
                        type: .delete, path: path,
                        message: "Deleted package (\(count) files; index update pending)")
                    completion.value(Self.wrapForCompletion(SyncError.indexUpdateFailedAfterCommit(detail)))
                case .rejected(let member, _):
                    // 中身がリモートで進んでいた（キャッシュの後の変化）。最新の item を添えて拒否する。
                    AppLogger.fileProvider.notice("deleteItem(package): rejected — remote changed inside package: \(member, privacy: .private)")
                    await services.events.append(
                        type: .info, path: path, message: "Delete rejected (remote changed inside package)")
                    guard let latest = try await services.cache.current().tree.node(at: path), latest.isPackage else {
                        await forgetLocalState()
                        completion.value(nil)
                        return
                    }
                    let materialized = await services.toldMaterializedFlag(for: path)
                    completion.value(NSError.fileProviderErrorForRejectedDeletion(
                        of: FileProviderItem(node: latest, materialized: materialized)))
                }
            } catch {
                AppLogger.fileProvider.error("deleteItem(package) failed: \(String(describing: error), privacy: .private)")
                if !(error is CancellationError) {
                    await services.events.append(
                        type: .error, path: path, message: "Delete failed",
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
        // パッケージ（`k:`・#140）はコンテナではない（中身は item にせず fetchContents が丸ごと返す）。
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
    /// ファイル = `f:<相対 POSIX パス>` / ディレクトリ = `d:<相対 POSIX パス>` /
    /// パッケージ = `k:<相対 POSIX パス>`（#140）。ルートは
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
    /// パッケージ = `k:<相対 POSIX パス>`（#140）。ファイルとも別の id にする — Keynote は同じ名前の
    /// 書類を単一ファイル ⇄ パッケージで保存し直せるので、`f:` を共用すると同じ id の種類変化
    /// （fileproviderd の `doc` ⇄ `pkg`）になる（ユーザ確定 2026-10-30）。
    static let tidePackagePrefix = "k:"

    /// Tide の item identifier → (相対 POSIX パス, 種類)。ルートは `("", .directory)`。
    /// working set / trash / 旧 `p:` / 未知の identifier は nil。
    /// 裸の `"f:"` / `"d:"` / `"k:"`（空パス）も nil = 不正 id（root の正規表現は `.rootContainer` のみ。
    /// 受理すると root 高速パス等が「要求 id と食い違う item」を成功応答しうる。自前の mint 経路は
    /// この形を作らないが、書込対応でデーモン供給 id を受ける面が増える前の防御。PR #57 レビュー #5）。
    var tidePathAndKind: TideItemRef? {
        if self == .rootContainer { return TideItemRef(path: "", kind: .directory) }
        for (prefix, kind) in [
            (Self.tideFilePrefix, ManifestTree.Node.Kind.file),
            (Self.tideDirectoryPrefix, .directory),
            (Self.tidePackagePrefix, .package),
        ] where rawValue.hasPrefix(prefix) {
            let path = String(rawValue.dropFirst(prefix.count))
            return path.isEmpty ? nil : TideItemRef(path: path, kind: kind)
        }
        return nil
    }

    /// 相対 POSIX パス + 種類 → Tide の item identifier。ルート（`""`）は `.rootContainer`。
    init(tideRelativePath path: String, kind: ManifestTree.Node.Kind) {
        if path.isEmpty {
            self = .rootContainer
        } else {
            let prefix: String
            switch kind {
            case .file: prefix = Self.tideFilePrefix
            case .directory: prefix = Self.tideDirectoryPrefix
            case .package: prefix = Self.tidePackagePrefix
            }
            self = NSFileProviderItemIdentifier(prefix + path)
        }
    }

    /// 相対 POSIX パス + ディレクトリか → Tide の item identifier（ファイルかディレクトリ）。
    init(tideRelativePath path: String, isDirectory: Bool) {
        self.init(tideRelativePath: path, kind: isDirectory ? .directory : .file)
    }

    /// ノード → item identifier（種類はノードから取る）。
    init(tideNode node: ManifestTree.Node) {
        self.init(tideRelativePath: node.path, kind: node.kind)
    }
}

/// item identifier を分解した結果（`NSFileProviderItemIdentifier.tidePathAndKind`）。
struct TideItemRef: Equatable {
    let path: String
    let kind: ManifestTree.Node.Kind
    var isDirectory: Bool { kind == .directory }
    var isPackage: Bool { kind == .package }
}
