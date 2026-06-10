import SwiftUI

/// 「Version History」ウィンドウの状態。S3 のバージョン列挙・復元アクションのドライバ。
/// 列挙/復元の重い処理（ネットワーク DL）は `TideS3Client` / `RestoreService` 側で off-main に走る。
@MainActor
@Observable
final class VersionHistoryModel {
    /// 過去バージョン参照タブ: ユーザが入力する相対パス。
    var pathInput: String = ""
    /// 直近に版を読み込んだ相対パス。
    var loadedPath: String? = nil
    /// `loadedPath` の版（時系列降順）。
    var versions: [FileVersion] = []

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
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    /// 再検索 / キャンセルのたびに進める世代。cancel は in-flight の await を即座には止められず、
    /// 復帰後の state 書込が新スキャンを潰しうるため、各書込前に世代一致を確認して stale を捨てる。
    @ObservationIgnored private var scanGeneration = 0

    /// 指定相対パスの全バージョン（delete marker 含む）を列挙して時系列降順に並べる。
    func loadVersions(for relativePathRaw: String, env: AppEnvironment) async {
        // ボタンは isLoading で disabled だが onSubmit / Choose… 経由は素通しなので再入をここで止める。
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
            // 復元で新しい現行版が増えるので履歴を更新。
            await loadVersions(for: path, env: env)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    // MARK: - 削除済みファイル（サブ E）

    /// `files/` 全体を明示的にフル列挙し、現在削除済み（最新が delete marker）かつ復元可能なファイルを集める。
    /// ページングしながら逐次表示し、キャンセル可能。ポーリングには乗せない（手動操作のみ）。
    func scanDeletedFiles(env: AppEnvironment) {
        guard let s3 = env.s3 else {
            errorMessage = String(localized: "Not configured")
            return
        }
        scanTask?.cancel()
        scanGeneration += 1
        let generation = scanGeneration
        isScanningDeleted = true
        errorMessage = nil
        restoreNote = nil
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
                    guard page.isTruncated else { break }
                    keyMarker = page.nextKeyMarker
                    versionIdMarker = page.nextVersionIdMarker
                }
            } catch {
                guard generation == self.scanGeneration else { return }
                if !Task.isCancelled { self.errorMessage = String(describing: error) }
            }
            if generation == self.scanGeneration {
                self.isScanningDeleted = false
            }
        }
    }

    func cancelDeletedScan() {
        scanTask?.cancel()
        scanGeneration += 1  // cancel が間に合わなかった stale 書込（await 復帰後）も世代不一致で抑止
        isScanningDeleted = false
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
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }
}
