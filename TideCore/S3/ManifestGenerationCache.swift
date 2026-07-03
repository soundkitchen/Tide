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
///   `enumerateChanges` → 直近リフレッシュ済みで新世代なし → 再発火しない（収束する）。
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
    private var inflight: Task<ManifestSnapshotLoader.SnapshotResult, Error>?

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
    /// ただし直近 `minRefreshInterval` 以内のロード結果はそのまま返す（バースト吸収）。
    public func refreshedCurrent() async throws -> Current {
        try await current(maxStaleness: minRefreshInterval)
    }

    /// anchor の世代（diff の起点）。世代落ち・未知 anchor は nil（= `.syncAnchorExpired` 行き）。
    public func generation(anchor: String) -> ManifestGenerationLog.Generation? {
        loadPayloadIfNeeded()
        return ManifestGenerationLog.generation(anchor: anchor, in: payload)
    }

    private func current(maxStaleness: TimeInterval) async throws -> Current {
        if let cached, Date().timeIntervalSince(cached.fetchedAt) < maxStaleness {
            return cached.current
        }
        loadPayloadIfNeeded()

        let snapshot: ManifestSnapshotLoader.SnapshotResult
        if let inflight {
            snapshot = try await inflight.value
        } else {
            let loader = self.loader
            let previous = ManifestGenerationLog.latest(of: payload).map {
                ManifestSnapshotLoader.SnapshotResult(files: $0.files, shardEtags: $0.shardEtags)
            }
            let task = Task { try await loader.load(previous: previous) }
            inflight = task
            defer { inflight = nil }
            snapshot = try await task.value
        }

        // ここからは actor 直列文脈。合流タスクの間に先行タスクが確定済みなら、それをそのまま返す
        // （同一 snapshot の再反映は idempotent だが、無駄な encode/写経を避ける）。
        if let cached, Date().timeIntervalSince(cached.fetchedAt) < maxStaleness {
            return cached.current
        }

        let fetchedAt = Date()
        let (newPayload, appended) = ManifestGenerationLog.appending(
            snapshot: snapshot, anchor: UUID().uuidString, fetchedAt: fetchedAt,
            to: payload, bucket: bucket
        )
        payload = newPayload
        if let logURL {
            do {
                try ManifestGenerationLog.save(newPayload, url: logURL)
            } catch {
                AppLogger.fileProvider.error("Generation log save failed: \(String(describing: error), privacy: .private)")
            }
        }
        // appending 後は必ず最新世代が存在する
        let latest = ManifestGenerationLog.latest(of: newPayload)!
        let current = Current(tree: ManifestTree(files: latest.files), anchor: latest.anchor)
        cached = (current, fetchedAt)
        if appended {
            onNewGeneration()
        }
        return current
    }

    private func loadPayloadIfNeeded() {
        guard !payloadLoaded else { return }
        payloadLoaded = true
        guard let logURL else { return }
        payload = ManifestGenerationLog.load(bucket: bucket, url: logURL)
    }
}
