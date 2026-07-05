import Foundation
import TideCore

/// `ManifestStore` のインメモリ・フェイク（M5 Phase 5-0）。
/// 実 S3 の楽観ロック意味論を模倣する:
/// - etag は書込ごとに連番で採番
/// - `ifMatch` 不一致 / `ifMatch == nil`（新規作成の意図）なのに既存あり → 412 相当を throw
///   （`S3ErrorClassifier.isPreconditionFailed` が拾う "PreconditionFailed" を含む記述）
/// - `failNextPutShard(times:)` で putShard を N 回だけ強制 412 にできる（リトライ経路の検証用）
actor InMemoryManifestStore: ManifestStore {
    struct SimulatedPreconditionFailure: Error, CustomStringConvertible {
        var description: String { "PreconditionFailed (simulated 412)" }
    }

    private(set) var index: ManifestIndex?
    private(set) var indexEtag: String?
    private(set) var shards: [String: ManifestShard] = [:]
    private(set) var shardEtags: [String: String] = [:]
    private var etagCounter = 0
    private var putShardFailuresRemaining = 0
    private var putIndexFailuresRemaining = 0

    /// 次の putShard を `times` 回だけ 412 で失敗させる。
    func failNextPutShard(times: Int) {
        putShardFailuresRemaining = times
    }

    /// 次の putIndex を `times` 回だけ 412 で失敗させる
    /// （putShard 成功 → updateIndex 失敗の分断を作る。PR #56 レビュー ① の再現用）。
    func failNextPutIndex(times: Int) {
        putIndexFailuresRemaining = times
    }

    /// テスト前提の直接投入（etag 検証を通さない）。index の shard 情報も同期する。
    func seed(shard: ManifestShard, deviceId: String = "seed-device") {
        let etag = mintEtag()
        shards[shard.shardId] = shard
        shardEtags[shard.shardId] = etag
        var idx = index ?? ManifestIndex.empty(updatedBy: deviceId)
        idx.shards[shard.shardId] = .init(etag: etag, count: shard.files.count)
        index = idx
        indexEtag = mintEtag()
    }

    private func mintEtag() -> String {
        etagCounter += 1
        return "etag-\(etagCounter)"
    }

    private func checkPrecondition(ifMatch: String?, current: String?) throws {
        // 実 S3Client の流儀: ifMatch == nil は ifNoneMatch:"*"（存在しなければ作成）に相当。
        if let ifMatch {
            guard ifMatch == current else { throw SimulatedPreconditionFailure() }
        } else {
            guard current == nil else { throw SimulatedPreconditionFailure() }
        }
    }

    // MARK: - ManifestStore

    func getIndex() throws -> TideS3Client.ManifestFetch<ManifestIndex>? {
        guard let index, let indexEtag else { return nil }
        return .init(value: index, etag: indexEtag)
    }

    func putIndex(_ newIndex: ManifestIndex, ifMatch: String?) throws -> String {
        if putIndexFailuresRemaining > 0 {
            putIndexFailuresRemaining -= 1
            throw SimulatedPreconditionFailure()
        }
        try checkPrecondition(ifMatch: ifMatch, current: indexEtag)
        index = newIndex
        let etag = mintEtag()
        indexEtag = etag
        return etag
    }

    func getShard(_ id: String) throws -> TideS3Client.ManifestFetch<ManifestShard>? {
        guard let shard = shards[id], let etag = shardEtags[id] else { return nil }
        return .init(value: shard, etag: etag)
    }

    func putShard(_ shard: ManifestShard, ifMatch: String?) throws -> String {
        if putShardFailuresRemaining > 0 {
            putShardFailuresRemaining -= 1
            throw SimulatedPreconditionFailure()
        }
        try checkPrecondition(ifMatch: ifMatch, current: shardEtags[shard.shardId])
        shards[shard.shardId] = shard
        let etag = mintEtag()
        shardEtags[shard.shardId] = etag
        return etag
    }

    func deleteShard(_ id: String) {
        shards.removeValue(forKey: id)
        shardEtags.removeValue(forKey: id)
    }
}
