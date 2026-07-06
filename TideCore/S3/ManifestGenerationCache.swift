import Foundation

/// マニフェスト世代のプロセス内キャッシュ + 永続世代ログ（`ManifestGenerationLog`）の所有者
/// （M5 Phase 4・File Provider 拡張用）。
///
/// - 役割: `enumerateItems` / `item(for:)` / `fetchContents` へ TTL キャッシュ済みツリーを返し、
///   `enumerateChanges` へ anchor ↔ 世代の解決と「今の世代」を返す。
/// - 書き手はこのアクターのみ（プロセス内直列化 + atomic 書出）。アプリ本体は触らない。
/// - single-flight: actor は await 中に reentrant なので、進行中ロードへ後続を合流させないと
///   コールドスタート（ドメイン起床直後の Finder バースト）で N 並列フルロードになる
///   （PR #50 レビュー #3 と同じ理由）。合流後の世代ログ反映は idempotent（同内容は
///   世代を増やさない）なので、どのタスクが先に確定しても結果は同じ。
/// - `onNewGeneration`: リフレッシュが新世代を検知（= リモート変化）した時に発火。拡張の
///   機会的自己 signal（`signalEnumerator(.workingSet)`）の配線先。signal → システムの
///   `enumerateChanges` → `refreshedCurrent` が signal 後開始のロードを保証 → 新世代なし →
///   再発火しない（収束する）。
public actor ManifestGenerationCache {
    /// 「今」の世代。tree は列挙・取得用、anchor は `NSFileProviderSyncAnchor` の中身。
    public struct Current: Sendable {
        public let tree: ManifestTree
        public let anchor: String
    }

    private let loader: ManifestSnapshotLoader
    private let bucket: String
    /// 永続世代ログの URL。nil = 永続化しない（読み書き失敗もベストエフォート）。
    private let logURL: URL?
    private let maxAge: TimeInterval
    /// `refreshedCurrent()`（signal 応答経路）の再ロード下限間隔。連続する enumerateChanges の
    /// バーストで S3 を叩き続けない床。
    private let minRefreshInterval: TimeInterval
    private let onNewGeneration: @Sendable () -> Void

    private var payload: ManifestGenerationLog.Payload?
    private var payloadLoaded = false
    private var cached: (current: Current, fetchedAt: Date)?
    /// 進行中の S3 ロードと**その開始時刻**。開始時刻を task と束ねて持つことで、合流者が
    /// `await` 後に共有可変状態を読んで開始時刻を取り違える窓（PR #58 レビュー #4）を塞ぐ。
    private var inflight: (task: Task<ManifestSnapshotLoader.SnapshotResult, Error>, startedAt: Date)?
    /// 最後に拡張自身の書込が S3 に確定した時刻（`invalidateAfterLocalWrite`・M5 Phase 5-2）。
    /// これより**前に開始**した S3 ロードの結果は「自分の書込を含まない巻き戻り snapshot」で、
    /// そのまま世代化すると旧 entry の didUpdate（実 bounce）になるため破棄して再ロードする。
    private var lastLocalWriteAt: Date?

    public init(
        loader: ManifestSnapshotLoader,
        bucket: String,
        logURL: URL?,
        maxAge: TimeInterval = 30,
        minRefreshInterval: TimeInterval = 2,
        onNewGeneration: @escaping @Sendable () -> Void = {}
    ) {
        self.loader = loader
        self.bucket = bucket
        self.logURL = logURL
        self.maxAge = maxAge
        self.minRefreshInterval = minRefreshInterval
        self.onNewGeneration = onNewGeneration
    }

    /// TTL 内は同じ世代を返す（列挙・item・fetch 用）。
    public func current() async throws -> Current {
        try await current(maxStaleness: maxAge)
    }

    /// signal 応答（`enumerateChanges`）用: TTL を待たずリフレッシュする。
    ///
    /// バースト吸収の床（`minRefreshInterval`）は、直近キャッシュが**呼び出し元と異なる世代**
    /// （`callerAnchor` 不一致 = diff を返せる）のときにだけ適用する。同じ世代のキャッシュに
    /// 床を適用すると「signal 直前にロードした変更前ツリーで『変更なし』と答えて signal を
    /// 消費する」取りこぼし窓になり、アプリ側 pull は取り込み済みで再 signal しないため
    /// staleness が次のリモート変更まで残る（PR #51 レビュー #1）。
    /// さらに使用するロードは **本呼び出し以降に開始したもの**に限る（signal 前開始の進行中
    /// ロードへ合流すると、signal の原因となった変更を含まない読みで「変更なし」と誤答しうる）
    /// — `current(minStartedAt:)` が閾値を満たすまで読み直して保証する。
    public func refreshedCurrent(callerAnchor: String?) async throws -> Current {
        if let cached, Date().timeIntervalSince(cached.fetchedAt) < minRefreshInterval,
           cached.current.anchor != callerAnchor {
            return cached.current
        }
        return try await current(maxStaleness: 0, minStartedAt: Date())
    }

    /// anchor の世代（diff の起点）。世代落ち・未知 anchor は nil（= `.syncAnchorExpired` 行き）。
    public func generation(anchor: String) -> ManifestGenerationLog.Generation? {
        loadPayloadIfNeeded()
        return ManifestGenerationLog.generation(anchor: anchor, in: payload)
    }

    /// - Parameter minStartedAt: 使用する S3 ロードは「これ以降に開始したもの」であることを保証する
    ///   （`refreshedCurrent` が signal 前開始の stale ロードで「変更なし」と誤答しないため）。
    private func current(maxStaleness: TimeInterval, minStartedAt: Date? = nil) async throws -> Current {
        if minStartedAt == nil, let cached, Date().timeIntervalSince(cached.fetchedAt) < maxStaleness {
            return cached.current
        }
        loadPayloadIfNeeded()

        var (snapshot, startedAt) = try await loadSnapshot(minStartedAt: nil)
        // stale ロード破棄（M5 Phase 5-2）: ローカル書込（`invalidateAfterLocalWrite`）より前、または
        // 呼び出し元が要求する `minStartedAt` より前に開始したロードは、その変更を含まない可能性が
        // ある。世代化すると「巻き戻り世代」→ 旧 entry の didUpdate = 実 bounce / signal 取りこぼしに
        // なるため、閾値より後に開始したロードを掴むまで読み直す。
        // **while ループ**（PR #58 レビュー #5）: 読み直し中にさらに書込が着地しても閾値を再評価して
        // 取りこぼさない。読み直しは「閾値以降に開始した inflight にのみ合流」= 書込前ロードへ再合流
        // しない（合流可なら N 者が 1 本へ集約・コールドロード嵐を避ける・レビュー #6）。
        while true {
            let threshold = max(lastLocalWriteAt ?? .distantPast, minStartedAt ?? .distantPast)
            if startedAt >= threshold { break }
            (snapshot, startedAt) = try await loadSnapshot(minStartedAt: threshold)
        }

        // ここからは actor 直列文脈。合流タスクの間に先行タスクが確定済みなら、それをそのまま返す
        // （同一 snapshot の再反映は idempotent だが、無駄な encode/写経を避ける）。
        if minStartedAt == nil, let cached, Date().timeIntervalSince(cached.fetchedAt) < maxStaleness {
            return cached.current
        }

        let fetchedAt = Date()
        let previousEtags = ManifestGenerationLog.latest(of: payload)?.shardEtags
        let (newPayload, appended) = ManifestGenerationLog.appending(
            snapshot: snapshot, anchor: UUID().uuidString, fetchedAt: fetchedAt,
            to: payload, bucket: bucket
        )
        payload = newPayload
        // 永続化は「世代が増えた or shard etag が実際に動いた」ときだけ。無変化リフレッシュの
        // たびに最大 8 世代分の全 files map を atomic 書出しするのは無駄で、永続側 fetchedAt は
        // 誰も読まない情報値（PR #51 レビュー #5。ログは消えても自己回復する設計なので安全側）。
        if let logURL, appended || previousEtags != snapshot.shardEtags {
            do {
                try ManifestGenerationLog.save(newPayload, url: logURL)
            } catch {
                AppLogger.fileProvider.error("Generation log save failed: \(String(describing: error), privacy: .private)")
            }
        }
        // appending 後は必ず最新世代が存在する
        let latest = ManifestGenerationLog.latest(of: newPayload)!
        let current: Current
        if !appended, let cached, cached.current.anchor == latest.anchor {
            // 無変化なら既存ツリーを再利用（ISO8601 parse 込みの O(N) 再構築を省く —
            // PR #51 レビュー #6）
            current = cached.current
        } else {
            current = Current(tree: ManifestTree(files: latest.files), anchor: latest.anchor)
        }
        cached = (current, fetchedAt)
        if appended {
            onNewGeneration()
        }
        return current
    }

    /// S3 からの snapshot ロード 1 回分。`minStartedAt` を渡すと、**それ以降に開始した** inflight に
    /// のみ合流する（書込前ロードへ再合流しないため。nil はどの inflight にも合流可）。
    /// - Returns: snapshot と、そのロードの**開始**時刻（合流時は合流先の開始時刻）。
    private func loadSnapshot(
        minStartedAt: Date?
    ) async throws -> (ManifestSnapshotLoader.SnapshotResult, Date) {
        if let inflight, minStartedAt == nil || inflight.startedAt >= minStartedAt! {
            // 開始時刻は await の**前**に捕捉する（await 後に共有可変状態を読むと、別タスクの
            // 再ロードが inflight を差し替えて開始時刻を取り違える。PR #58 レビュー #4）。
            let startedAt = inflight.startedAt
            return (try await inflight.task.value, startedAt)
        }
        let loader = self.loader
        let previous = ManifestGenerationLog.latest(of: payload).map {
            ManifestSnapshotLoader.SnapshotResult(files: $0.files, shardEtags: $0.shardEtags)
        }
        let startedAt = Date()
        let task = Task { try await loader.load(previous: previous) }
        inflight = (task, startedAt)
        // 自分の task がまだ載っているときだけクリアする（合流者の再ロードが差し込んだ別 task を
        // 握り潰して single-flight を壊さない。Task は identity で Equatable。PR #58 レビュー #6）。
        defer { if inflight?.task == task { inflight = nil } }
        return (try await task.value, startedAt)
    }

    /// 拡張自身の書込（M5 Phase 5-2・「拡張 = 第 3 のデバイス」）が **S3 に確定した後**に呼ぶ。
    /// 世代を**局所構築せず**、キャッシュを無効化して次の `current()` / `enumerateChanges` が
    /// S3 から読み直すようにする（S3 は既に自分の書込を反映済み）。
    ///
    /// 局所構築（旧 `recordLocalChange`）は撤去した（PR #58 レビュー #2/#3）: cold 時に他シャードを
    /// 欠いた near-empty 世代を捏造して 30 秒配信し、温世代 + live etag では他デバイスの同シャード
    /// 追加ファイルを恒久的に隠していた。S3 読み直しは truth を単一の出所にする。
    /// - `lastLocalWriteAt` を前進 → 書込前に開始した進行中ロードが stale 破棄される（bounce 防止）。
    /// - `cached = nil` → 次の `current()` が必ず読み直す。
    /// - `onNewGeneration`（= 自己 signal）で列挙者にリフレッシュを促す。
    /// completion で返した item（書いた entry から生成）と、読み直し後の enumerateChanges が配る
    /// item は同一 itemVersion（= sha256）なので、システム側の再適用は no-op = bounce しない。
    public func invalidateAfterLocalWrite() {
        cached = nil
        lastLocalWriteAt = Date()
        onNewGeneration()
    }

    private func loadPayloadIfNeeded() {
        guard !payloadLoaded else { return }
        payloadLoaded = true
        guard let logURL else { return }
        payload = ManifestGenerationLog.load(bucket: bucket, url: logURL)
    }
}
