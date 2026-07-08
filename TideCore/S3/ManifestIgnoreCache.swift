import Foundation

/// `ManifestIgnoreCache` の取得系エラー。
public enum ManifestIgnoreCacheError: Error, Equatable {
    /// versionId 固定で取得した `.syncignore` の内容がマニフェスト宣言の sha256 と一致しない
    /// （版オブジェクトは不変なので、実質マニフェスト破損 or ストレージ異常）。呼び出し側の
    /// createItem は一時エラーとして失敗し、システムの再試行（次世代ロード）に委ねる。
    case contentMismatch(path: String)
}

/// FP ドメインの新規作成（createItem・M5 Phase 5-3）に適用するユーザ `.syncignore` 群を、
/// **マニフェスト経由**で構築・キャッシュする actor。
///
/// 拡張にはローカル同期フォルダが無いため、`.syncignore` の真実は「マニフェストが宣言する
/// 同期済み `.syncignore` ファイル群」= S3 上の内容（アプリが pull 後にローカルで読むものと同一）。
/// FSEvents モードの `SyncEngine.loadLayeredIgnore` と同じ防御境界で `LayeredSyncIgnore` を組む:
/// - `LayeredSyncIgnore.maxFiles` 超過分は浅い層優先で打ち切り（除外しない＝同期する安全側）
/// - `SyncIgnoreMatcher.maxBytes` 超過ファイルは先頭のみパース（アプリの読込打ち切りと同じ）
///
/// キャッシュ戦略（アプリ側の「変更時フル再構築」の世代版）:
/// - 世代アンカーをキーに構築結果をキャッシュ。同一世代の再要求はゼロコスト、並行要求は
///   single-flight で合流（フォルダドラッグ = 大量並行 createItem での多重構築を防ぐ）。
/// - ファイル単位で (path, 宣言 sha256) → パース済みマッチャをメモ化。世代が進んでも
///   `.syncignore` 自体が変わっていなければ再取得しない（定常コストは実質ゼロ）。
/// - 取得は versionId 固定 + 全バイト sha256 検証（enumerate と同じ「宣言した版を読む」規約）。
///   pinned 版消失（旧版失効）は最新版へフォールバック、それも無ければその層をスキップ
///   （除外しない安全側）。fetch の失敗は throw = createItem が一時エラーで再試行される
///   （アップロード自体に S3 が要るので可用性は悪化しない）。
public actor ManifestIgnoreCache {
    /// `.syncignore` 1 ファイルの取得結果。`sha256` は**全バイト**のハッシュ（打ち切り前）、
    /// `prefix` は先頭 `maxPrefixBytes` のみ。404 / NoSuchVersion は nil を返すこと。
    public struct FetchedFile: Sendable {
        public let sha256: String
        public let prefix: Data

        public init(sha256: String, prefix: Data) {
            self.sha256 = sha256
            self.prefix = prefix
        }
    }

    /// `.syncignore` 本体の取得（実体は拡張側の S3 streamObject ラッパ。テストではフェイク）。
    public typealias Fetch = @Sendable (
        _ path: String, _ versionId: String?, _ maxPrefixBytes: Int
    ) async throws -> FetchedFile?

    private let fetch: Fetch
    private var cachedAnchor: String?
    private var cachedLayered = LayeredSyncIgnore.empty
    /// path → (マニフェスト宣言 sha256, パース済みマッチャ)。世代を跨いで再利用する。
    private var matcherMemo: [String: (sha: String, matcher: SyncIgnoreMatcher)] = [:]
    private var inflight: (anchor: String, task: Task<LayeredSyncIgnore, Error>)?

    public init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    /// 世代（`tree` + `anchor`）に対応する `LayeredSyncIgnore` を返す。
    public func layeredIgnore(tree: ManifestTree, anchor: String) async throws -> LayeredSyncIgnore {
        if anchor == cachedAnchor {
            return cachedLayered
        }
        if let inflight, inflight.anchor == anchor {
            return try await inflight.task.value
        }
        let task = Task { try await build(tree: tree) }
        inflight = (anchor, task)
        defer {
            // 自分が張った in-flight だけ畳む（別 anchor の後続が張り直した分を握り潰さない）
            if inflight?.anchor == anchor { inflight = nil }
        }
        let layered = try await task.value
        cachedAnchor = anchor
        cachedLayered = layered
        return layered
    }

    private func build(tree: ManifestTree) async throws -> LayeredSyncIgnore {
        // マニフェスト中の `.syncignore` ファイル（ルート/ネスト）を浅い→深い順に収集し、
        // 上限超過分は打ち切る（深い層から捨てる = 影響範囲の狭い層を諦める安全側）。
        var candidates: [(path: String, entry: ManifestFileEntry)] = []
        for (path, node) in tree.nodesByPath {
            guard case .file(_, let entry) = node, IgnoreDecision.isSyncignoreFile(path) else {
                continue
            }
            candidates.append((path, entry))
        }
        candidates.sort {
            let d0 = $0.path.count(where: { $0 == "/" })
            let d1 = $1.path.count(where: { $0 == "/" })
            return d0 != d1 ? d0 < d1 : $0.path < $1.path
        }
        if candidates.count > LayeredSyncIgnore.maxFiles {
            AppLogger.fileProvider.notice(
                "ignore cache: .syncignore count exceeds cap; dropping \(candidates.count - LayeredSyncIgnore.maxFiles) deepest (not excluding = syncing)"
            )
            candidates = Array(candidates.prefix(LayeredSyncIgnore.maxFiles))
        }

        var matchers: [String: SyncIgnoreMatcher] = [:]
        var newMemo: [String: (sha: String, matcher: SyncIgnoreMatcher)] = [:]
        for (path, entry) in candidates {
            // "a/b/.syncignore" → 層キー "a/b"、ルート ".syncignore" → ""
            let dirKey = path == ".syncignore" ? "" : String(path.dropLast(".syncignore".count + 1))
            let matcher: SyncIgnoreMatcher
            if let memo = matcherMemo[path], memo.sha == entry.sha256 {
                matcher = memo.matcher
            } else if let parsed = try await fetchAndParse(path: path, entry: entry) {
                matcher = parsed
            } else {
                continue  // 404 両振り = 層スキップ（除外しない安全側）
            }
            newMemo[path] = (entry.sha256, matcher)
            matchers[dirKey] = matcher
        }
        // 消えた `.syncignore` のメモは世代ごとに刈る（メモリの単調増加防止）
        matcherMemo = newMemo
        return LayeredSyncIgnore(matchers: matchers)
    }

    private func fetchAndParse(
        path: String, entry: ManifestFileEntry
    ) async throws -> SyncIgnoreMatcher? {
        if let versionId = entry.s3VersionId {
            if let pinned = try await fetch(path, versionId, SyncIgnoreMatcher.maxBytes) {
                guard pinned.sha256 == entry.sha256 else {
                    AppLogger.fileProvider.error(
                        "ignore cache: pinned content hash mismatch: \(path, privacy: .private)")
                    throw ManifestIgnoreCacheError.contentMismatch(path: path)
                }
                return SyncIgnoreMatcher.parse(String(decoding: pinned.prefix, as: UTF8.self))
            }
            // 宣言版が消えている（旧版失効等）→ 最新版フォールバック。内容はより新しい側 =
            // アプリが pull 後にローカルで読むものへ近づく方向なので受理する（sha 検証なし。
            // メモは宣言 sha キーのままなので、マニフェストが追いつけば自然に取り直す）。
            AppLogger.fileProvider.notice(
                "ignore cache: pinned version missing; falling back to latest: \(path, privacy: .private)")
            guard let latest = try await fetch(path, nil, SyncIgnoreMatcher.maxBytes) else {
                return nil
            }
            return SyncIgnoreMatcher.parse(String(decoding: latest.prefix, as: UTF8.self))
        }
        guard let latest = try await fetch(path, nil, SyncIgnoreMatcher.maxBytes) else {
            return nil
        }
        guard latest.sha256 == entry.sha256 else {
            // versionId 無し（理論上ほぼ無い）+ 内容不一致 = 並行更新のレース。一時エラーで
            // 再試行に委ねる（次の試行では新世代のマニフェストを読む）。
            throw ManifestIgnoreCacheError.contentMismatch(path: path)
        }
        return SyncIgnoreMatcher.parse(String(decoding: latest.prefix, as: UTF8.self))
    }
}
