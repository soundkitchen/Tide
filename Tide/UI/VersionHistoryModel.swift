import TideCore
import SwiftUI

/// 「Version History」ウィンドウの状態。S3 のバージョン列挙・復元アクションのドライバ。
/// 列挙/復元の重い処理（ネットワーク DL）は `TideS3Client` / `RestoreService` 側で off-main に走る。
@MainActor
@Observable
final class VersionHistoryModel {
    /// 過去バージョン参照タブ: ユーザが入力する相対パス。同期一覧の絞り込み検索も兼ねる
    /// （打鍵で `filteredSyncedPaths` がライブに絞られ、Enter で任意パスを直接読込）。
    var pathInput: String = ""
    /// 直近に版を読み込んだ相対パス。
    var loadedPath: String? = nil
    /// `loadedPath` の版（時系列降順）。
    var versions: [FileVersion] = []

    /// ローカル DB（`files`）にある同期済み相対パス一覧（自然順ソート済み）。
    /// オープン/タブ表示時に 1 回読み、絞り込みはメモリ内で完結（I/O ゼロ）。
    var syncedPaths: [String] = []

    /// `pathInput` を部分一致クエリとして `syncedPaths` を絞った結果（空入力なら全件）。
    var filteredSyncedPaths: [String] {
        let q = pathInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return syncedPaths }
        return syncedPaths.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    var isLoading = false
    var isRestoring = false
    var errorMessage: String? = nil
    /// 復元成功時の案内（パスは verbatim で連結）。
    var restoreNote: String? = nil

    /// 削除済みタブ: 現在削除済み（最新が delete marker）かつ復元可能なファイル一覧。
    var deletedFiles: [FileVersionHistory] = []
    var isScanningDeleted = false
    /// 走査済みの版・marker 件数（進捗表示用）。
    var deletedScanned = 0
    /// 削除一覧の軽量キャッシュ（#29 (b)）を最後にフル列挙した時刻。nil＝まだ一度も列挙していない。
    /// **フル完走した一覧にのみ対応する**（中断/失敗の部分結果には進めない）。UI は「Last updated …」
    /// 表示と、ボタン文言（Refresh / Search）・空状態文言（「No deleted files.」断定）の出し分けに使う。
    var deletedCacheUpdatedAt: Date? = nil
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    /// 再検索 / キャンセルのたびに進める世代。cancel は in-flight の await を即座には止められず、
    /// 復帰後の state 書込が新スキャンを潰しうるため、各書込前に世代一致を確認して stale を捨てる。
    @ObservationIgnored private var scanGeneration = 0
    /// スキャン開始直前の一覧スナップショット。中断/失敗時はこれへ戻す（#47 レビュー #1：空＋古い
    /// 「Last updated」を断定表示する後退を防ぐ＝未完走のときは直前のキャッシュ一覧をそのまま見せる）。
    @ObservationIgnored private var preScanDeleted: [FileVersionHistory] = []
    /// 現在 in-memory に保持している削除一覧が属する bucket（load/フル完走 save 時に確定）。
    /// restore 後の再保存は現在 config ではなくこれをキーに使う（#47 レビュー #2：表示中の bucket 変更で
    /// 旧一覧を新 bucket キーに汚染しない）。
    @ObservationIgnored private var deletedCacheBucket: String? = nil
    /// 削除一覧キャッシュ書込の直列化チェーン（#47 レビュー #3：複数 detached 書込の last-writer-wins 防止）。
    @ObservationIgnored private var cacheSaveTask: Task<Void, Never>?

    /// ローカル DB の `files` から同期済み相対パスを取り込み、自然順にソートして保持する。
    /// 失敗しても致命ではない（一覧が空のまま手入力で代替できる）ので握りつぶす。
    func loadSyncedPaths(env: AppEnvironment) async {
        guard let db = env.database else { return }
        do {
            let paths = try await db.pool.read { db in
                try FileRecord.fetchAll(db).map(\.path)
            }
            syncedPaths = paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        } catch {
            AppLogger.ui.error("Failed to load synced paths: \(String(describing: error), privacy: .private)")
        }
    }

    /// 指定相対パスの全バージョン（delete marker 含む）を列挙して時系列降順に並べる。
    func loadVersions(for relativePathRaw: String, env: AppEnvironment) async {
        // ボタンは isLoading で disabled だが onSubmit / 同期一覧の行クリック経由は素通しなので再入をここで止める。
        if isLoading { return }
        let relativePath = relativePathRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !relativePath.isEmpty else { return }
        guard let s3 = env.s3 else {
            errorMessage = String(localized: "Not configured")
            return
        }
        isLoading = true
        errorMessage = nil
        restoreNote = nil
        versions = []
        loadedPath = nil
        defer { isLoading = false }

        do {
            // 特定ファイルは prefix で 1 key に絞れるので安価（複数ページは稀だが一応たどる）。
            let prefix = "files/\(relativePath)"
            var allVersions: [TideS3Client.S3ObjectVersionRaw] = []
            var allMarkers: [TideS3Client.S3DeleteMarkerRaw] = []
            var keyMarker: String? = nil
            var versionIdMarker: String? = nil
            while true {
                let page = try await s3.listObjectVersions(
                    prefix: prefix, keyMarker: keyMarker, versionIdMarker: versionIdMarker
                )
                allVersions.append(contentsOf: page.versions)
                allMarkers.append(contentsOf: page.deleteMarkers)
                guard page.isTruncated else { break }
                keyMarker = page.nextKeyMarker
                versionIdMarker = page.nextVersionIdMarker
            }
            let histories = ObjectVersionHistory.group(versions: allVersions, deleteMarkers: allMarkers)
            loadedPath = relativePath
            if let h = histories.first(where: { $0.relativePath == relativePath }) {
                versions = h.versions
            } else {
                errorMessage = String(localized: "No versions found for this file.")
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// 選んだ版をローカルへ復元する（`SyncEngine.restore` 経由 → 再アップロード）。
    func restore(_ version: FileVersion, env: AppEnvironment) async {
        guard let path = loadedPath else { return }
        guard let engine = env.engine else {
            errorMessage = String(localized: "Not configured")
            return
        }
        isRestoring = true
        errorMessage = nil
        restoreNote = nil
        defer { isRestoring = false }

        do {
            let result = try await engine.restore(relativePath: path, versionId: version.versionId)
            let label = result.diverted
                ? String(localized: "Restored as a copy:")
                : String(localized: "Restored to:")
            restoreNote = "\(label) \(result.writtenRelativePath)"
            // 削除済みだったパスを Versions タブから原パス復元したら、Deleted 一覧/キャッシュからも外す
            // （#47 レビュー #5：restoreDeleted との対称性。2 つの復元経路で削除一覧の扱いを揃える）。
            if !result.diverted, deletedFiles.contains(where: { $0.relativePath == path }) {
                deletedFiles.removeAll { $0.relativePath == path }
                persistDeletedCacheAfterRemoval()
            }
            // 復元で新しい現行版が増えるので履歴を更新。
            await loadVersions(for: path, env: env)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    // MARK: - 削除済みファイル（サブ E）

    /// 削除一覧の軽量キャッシュ（#29 (b)）を読み、タブを開いた瞬間に前回スナップショットを即表示する。
    /// 現在 bucket と一致するキャッシュがあり、かつ未スキャン・一覧が空のときだけ反映する
    /// （ライブなスキャン結果を後追いで潰さない）。読込は off-main、失敗は無視（ベストエフォート）。
    func loadDeletedCache(env: AppEnvironment) async {
        guard let bucket = env.config.bucketName else { return }
        let payload = await Task.detached(priority: .utility) {
            DeletedFilesCache.load(bucket: bucket)
        }.value
        guard let payload, !isScanningDeleted, deletedFiles.isEmpty, deletedCacheUpdatedAt == nil else { return }
        deletedFiles = payload.files
        deletedCacheUpdatedAt = payload.updatedAt
        deletedCacheBucket = bucket
    }

    /// 削除一覧キャッシュのスナップショットを永続化する。全書込を 1 本のチェーンに直列化し（FIFO）、
    /// 複数 detached 書込の last-writer-wins を防ぐ（#47 レビュー #3）。`advanceTimestamp` のときは
    /// **書込成功後に** `deletedCacheUpdatedAt` / `deletedCacheBucket` を確定する（#47 レビュー #4：
    /// 書込失敗時に「Last updated 今」だけ進んでディスクが古い、という齟齬を作らない）。
    private func persistDeletedCacheSnapshot(
        files: [FileVersionHistory], bucket: String, updatedAt: Date, advanceTimestamp: Bool
    ) {
        let previous = cacheSaveTask
        // 非 detached の Task は @MainActor を継承する（state 更新は安全）。前のチェーン書込を待ってから
        // 実 IO だけ detached（Sendable 値のみキャプチャ・self は渡さない）で main から外す。
        cacheSaveTask = Task { [weak self] in
            await previous?.value
            let ok = await Task.detached(priority: .utility) { () -> Bool in
                do {
                    try DeletedFilesCache.save(files: files, bucket: bucket, updatedAt: updatedAt)
                    return true
                } catch {
                    AppLogger.ui.error("Failed to save deleted-files cache: \(String(describing: error), privacy: .private)")
                    return false
                }
            }.value
            guard let self else { return }
            if ok && advanceTimestamp {
                self.deletedCacheUpdatedAt = updatedAt
                self.deletedCacheBucket = bucket
            }
        }
    }

    /// `files/` 全体を明示的にフル列挙し、現在削除済み（最新が delete marker）かつ復元可能なファイルを集める。
    /// ページングしながら逐次表示し、キャンセル可能。ポーリングには乗せない（手動操作のみ）。
    /// フル完走したスナップショットは `DeletedFilesCache` に保存し、次回オープン時に即表示できるようにする。
    func scanDeletedFiles(env: AppEnvironment) {
        guard let s3 = env.s3 else {
            errorMessage = String(localized: "Not configured")
            return
        }
        let bucket = env.config.bucketName
        scanTask?.cancel()
        scanGeneration += 1
        let generation = scanGeneration
        isScanningDeleted = true
        errorMessage = nil
        restoreNote = nil
        preScanDeleted = deletedFiles  // 中断/失敗時に戻すため直前の一覧を退避（#47 レビュー #1）
        deletedFiles = []
        deletedScanned = 0
        // @MainActor メソッド内の Task は MainActor を継承する（state 更新は安全）。
        // listObjectVersions の待機はネットワークなので off-main に逃げ、累積全件の再グルーピング
        // （全体ソート含む・大規模バケットでは累積 × ページ数で効く）も detached で main から外す。
        // 各 await 復帰後の書込は世代一致のときだけ行う（stale タスクが現役スキャンの状態を潰さない）。
        scanTask = Task { [weak self] in
            guard let self else { return }
            var allVersions: [TideS3Client.S3ObjectVersionRaw] = []
            var allMarkers: [TideS3Client.S3DeleteMarkerRaw] = []
            var keyMarker: String? = nil
            var versionIdMarker: String? = nil
            var completedFully = false
            do {
                while !Task.isCancelled {
                    let page = try await s3.listObjectVersions(
                        prefix: "files/", keyMarker: keyMarker, versionIdMarker: versionIdMarker
                    )
                    guard generation == self.scanGeneration else { return }
                    allVersions.append(contentsOf: page.versions)
                    allMarkers.append(contentsOf: page.deleteMarkers)
                    // 毎ページ全体を再グルーピング（key がページ跨ぎでも最終結果は常に正しく、途中表示は自己補正）。
                    let snapshotVersions = allVersions
                    let snapshotMarkers = allMarkers
                    let deleted = await Task.detached(priority: .userInitiated) {
                        ObjectVersionHistory.deletedFiles(
                            ObjectVersionHistory.group(versions: snapshotVersions, deleteMarkers: snapshotMarkers)
                        )
                    }.value
                    guard generation == self.scanGeneration else { return }
                    self.deletedFiles = deleted
                    self.deletedScanned = allVersions.count + allMarkers.count
                    guard page.isTruncated else { completedFully = true; break }
                    keyMarker = page.nextKeyMarker
                    versionIdMarker = page.nextVersionIdMarker
                }
            } catch {
                guard generation == self.scanGeneration else { return }
                if !Task.isCancelled { self.errorMessage = String(describing: error) }
            }
            if generation == self.scanGeneration {
                self.isScanningDeleted = false
                if completedFully, let bucket {
                    // フル完走したときだけキャッシュ更新（part 結果は保存しない）。updatedAt は
                    // 書込成功後に確定する（#47 レビュー #4・persistDeletedCacheSnapshot 内）。
                    self.persistDeletedCacheSnapshot(
                        files: self.deletedFiles, bucket: bucket, updatedAt: Date(), advanceTimestamp: true
                    )
                } else {
                    // 中断（エラー）したら直前の一覧へ戻す（#47 レビュー #1：空＋古い「Last updated」の矛盾表示を防ぐ）。
                    // cancel 経路は世代不一致でここに来ないので cancelDeletedScan 側で戻す。
                    self.deletedFiles = self.preScanDeleted
                }
            }
        }
    }

    func cancelDeletedScan() {
        scanTask?.cancel()
        scanGeneration += 1  // cancel が間に合わなかった stale 書込（await 復帰後）も世代不一致で抑止
        isScanningDeleted = false
        // 中断したら直前の一覧へ戻す（#47 レビュー #1）。deletedCacheUpdatedAt は未完走では進めていないので
        // 直前の値のまま＝一覧とタイムスタンプが整合する。
        deletedFiles = preScanDeleted
        deletedScanned = 0
    }

    /// 削除済みファイルを、delete marker 直前の実体版で復元する。
    func restoreDeleted(_ history: FileVersionHistory, env: AppEnvironment) async {
        guard let engine = env.engine else {
            errorMessage = String(localized: "Not configured")
            return
        }
        guard let version = history.latestRestorableVersion else { return }
        isRestoring = true
        errorMessage = nil
        restoreNote = nil
        defer { isRestoring = false }

        do {
            let result = try await engine.restore(
                relativePath: history.relativePath, versionId: version.versionId
            )
            let label = result.diverted
                ? String(localized: "Restored as a copy:")
                : String(localized: "Restored to:")
            restoreNote = "\(label) \(result.writtenRelativePath)"
            // 原パスへ復元できたときだけ一覧から外す。divert（別名退避）時は原 key が
            // delete marker のまま＝引き続き「現在削除済み」なので残す。
            if !result.diverted {
                deletedFiles.removeAll { $0.relativePath == history.relativePath }
                persistDeletedCacheAfterRemoval()
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// 一覧から 1 件除去した後にキャッシュを整合させる（フル再列挙ではないので `updatedAt` は進めない）。
    /// 保存先 bucket は走査/読込時に確定した `deletedCacheBucket` を使う（#47 レビュー #2：表示中の
    /// bucket 変更で旧一覧を新 bucket キーへ汚染しない）。書込は直列化チェーン経由（#47 レビュー #3）。
    private func persistDeletedCacheAfterRemoval() {
        guard let updatedAt = deletedCacheUpdatedAt, let bucket = deletedCacheBucket else { return }
        persistDeletedCacheSnapshot(files: deletedFiles, bucket: bucket, updatedAt: updatedAt, advanceTimestamp: false)
    }
}
