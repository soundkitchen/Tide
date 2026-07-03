import Foundation

/// `ManifestSnapshotLoader` がマニフェストを読むための最小シーム（テスト差し替え用）。
public protocol ManifestSnapshotSource: Sendable {
    func getIndex() async throws -> TideS3Client.ManifestFetch<ManifestIndex>?
    func getShard(_ id: String) async throws -> TideS3Client.ManifestFetch<ManifestShard>?
}

extension TideS3Client: ManifestSnapshotSource {}

/// index + シャードを読んでリモート全体像を返す、読み取り専用のマニフェストローダ
/// （M5 Phase 3〜・File Provider 拡張用）。
///
/// `ManifestReader` と違い **DB に一切依存しない**（shard_state キャッシュの読み書きも
/// files テーブルからの補完もしない）。拡張プロセスから共有 DB へ書くと app 側と
/// 2 プロセス書込競合になるため、読み取り経路では書込ゼロを構造で保証する
/// （単一書き手＝拡張への移行は Phase 6）。
///
/// Phase 4 の増分読み: 前回スナップショット（`SnapshotResult`）を渡すと、index の shard etag
/// 差分で**変化したシャードだけ**を取得し、無変化シャードのファイルは前回分を持ち越す
/// （etag の意味論は `ManifestReader` の shard_state と同一 = 比較は index 宣言値、記録は取得
/// オブジェクトの実 etag）。前回なし（cold）は全シャード取得。
///
/// セキュリティゲートは `ManifestReader.read` と同一: shardId は取得前に
/// `PathValidator.validateShardId`、path は取り込み前に `PathValidator.validateRelativePath`。
public struct ManifestSnapshotLoader: Sendable {
    /// 1 回のロード結果。`files` がツリーの材料、`shardEtags` が次回の増分判定の材料。
    public struct SnapshotResult: Sendable, Equatable {
        public var files: [String: ManifestFileEntry]
        /// shardId → 取得済みシャードオブジェクトの etag（次回ロードで index 宣言値と比較する）。
        /// 取得に失敗（404 レース等）したシャードは記録しない＝次回必ず再取得される。
        public var shardEtags: [String: String]

        public init(files: [String: ManifestFileEntry], shardEtags: [String: String]) {
            self.files = files
            self.shardEtags = shardEtags
        }
    }

    public let source: ManifestSnapshotSource

    public init(source: ManifestSnapshotSource) {
        self.source = source
    }

    /// リモート全ファイルのスナップショットを返す。index が無ければ空（未同期バケット）。
    public func load() async throws -> [String: ManifestFileEntry] {
        try await load(previous: nil).files
    }

    /// 増分スナップショット。`previous` の shard etag と一致するシャードは取得せず持ち越す。
    /// index が無ければ空（未同期バケット＝リモート全削除と同義。`ManifestReader` と同じ意味論）。
    public func load(previous: SnapshotResult?) async throws -> SnapshotResult {
        guard let index = try await source.getIndex() else {
            return SnapshotResult(files: [:], shardEtags: [:])
        }

        // shardId 検証（不正な値が S3 キーに組み立てられる前に捨てる）
        let remoteShardEtags: [String: String] = index.value.shards.reduce(into: [:]) { acc, item in
            do {
                try PathValidator.validateShardId(item.key)
                acc[item.key] = item.value.etag
            } catch {
                AppLogger.s3.error("Rejected invalid shard id from manifest: \(item.key, privacy: .private)")
            }
        }

        // 変更検出（cold = 全取得）
        let cached = previous?.shardEtags ?? [:]
        let toFetch = remoteShardEtags.filter { cached[$0.key] != $0.value }.map(\.key)
        let unchangedIds = Set(remoteShardEtags.keys).subtracting(toFetch)

        // 変化したシャードを並列取得（最大 8 並列）。有界並列の骨格は BoundedParallel に一元化
        //（`group.next()` 結果の取りこぼし罠ごと封じる — PR #50 レビュー #7）。
        let source = self.source
        let fetched: [(id: String, shard: ManifestShard, etag: String)] =
            try await BoundedParallel.compactMap(toFetch) { shardId in
                guard let f = try await source.getShard(shardId) else { return nil }
                return (shardId, f.value, f.etag)
            }

        var files: [String: ManifestFileEntry] = [:]
        var shardEtags: [String: String] = [:]

        // 無変化シャード分は前回スナップショットから持ち越す（path は前回取り込み時に検証済み）。
        // index から消えたシャードのファイルはここで自然に脱落する（＝配下全削除の反映）。
        if let previous, !unchangedIds.isEmpty {
            for (path, entry) in previous.files
            where unchangedIds.contains(ManifestSharding.shardId(for: path)) {
                files[path] = entry
            }
            for id in unchangedIds {
                if let etag = previous.shardEtags[id] { shardEtags[id] = etag }
            }
        }

        // 取得分: path 検証しつつ取り込み
        for (id, shard, etag) in fetched {
            shardEtags[id] = etag
            for (path, entry) in shard.files {
                do {
                    try PathValidator.validateRelativePath(path)
                    files[path] = entry
                } catch {
                    AppLogger.s3.error("Rejected unsafe path from shard: \(path, privacy: .private)")
                }
            }
        }
        return SnapshotResult(files: files, shardEtags: shardEtags)
    }
}
