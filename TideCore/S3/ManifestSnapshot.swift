import Foundation

/// `ManifestSnapshotLoader` がマニフェストを読むための最小シーム（テスト差し替え用）。
public protocol ManifestSnapshotSource: Sendable {
    func getIndex() async throws -> TideS3Client.ManifestFetch<ManifestIndex>?
    func getShard(_ id: String) async throws -> TideS3Client.ManifestFetch<ManifestShard>?
}

extension TideS3Client: ManifestSnapshotSource {}

/// index + **全シャード**を読んでリモート全体像を返す、読み取り専用のマニフェストローダ
/// （M5 Phase 3・File Provider 拡張用）。
///
/// `ManifestReader` と違い **DB に一切依存しない**（shard_state キャッシュの読み書きも
/// files テーブルからの補完もしない）。拡張プロセスから共有 DB へ書くと app 側と
/// 2 プロセス書込競合になるため、Phase 3 の読み取り PoC では書込ゼロを構造で保証する
/// （単一書き手＝拡張への移行は Phase 6）。キャッシュが無いぶん毎回全シャードを取得するが、
/// 個人規模のバケット（シャード最大 256・実際は数個）では十分軽い。
///
/// セキュリティゲートは `ManifestReader.read` と同一: shardId は取得前に
/// `PathValidator.validateShardId`、path は取り込み前に `PathValidator.validateRelativePath`。
public struct ManifestSnapshotLoader: Sendable {
    public let source: ManifestSnapshotSource

    public init(source: ManifestSnapshotSource) {
        self.source = source
    }

    /// リモート全ファイルのスナップショットを返す。index が無ければ空（未同期バケット）。
    public func load() async throws -> [String: ManifestFileEntry] {
        guard let index = try await source.getIndex() else { return [:] }

        // shardId 検証（不正な値が S3 キーに組み立てられる前に捨てる）
        let shardIds: [String] = index.value.shards.keys.compactMap { id in
            do {
                try PathValidator.validateShardId(id)
                return id
            } catch {
                AppLogger.s3.error("Rejected invalid shard id from manifest: \(id, privacy: .private)")
                return nil
            }
        }

        // 全シャードを並列取得（最大 8 並列）。有界並列の骨格は BoundedParallel に一元化
        //（`group.next()` 結果の取りこぼし罠ごと封じる — PR #50 レビュー #7）。
        let source = self.source
        let shards = try await BoundedParallel.compactMap(shardIds) { shardId in
            try await source.getShard(shardId)?.value
        }

        // path 検証しつつ全ファイルマップへ集約
        var files: [String: ManifestFileEntry] = [:]
        for shard in shards {
            for (path, entry) in shard.files {
                do {
                    try PathValidator.validateRelativePath(path)
                    files[path] = entry
                } catch {
                    AppLogger.s3.error("Rejected unsafe path from shard: \(path, privacy: .private)")
                }
            }
        }
        return files
    }
}
