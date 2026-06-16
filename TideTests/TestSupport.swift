import XCTest
import CryptoKit
@testable import Tide

/// 複数テストで重複していたセットアップ / フィクスチャ生成の共通基盤。
/// 各テストファイルの `makeEnv` / `makeDB` は本ヘルパへ委譲し、`seedShardState` / `shardEtag` /
/// `seedLogs` は本拡張へ集約した（同一実装の重複を排除）。

extension XCTestCase {
    /// 一時 base ディレクトリ（UUID）配下に root / tmp と LocalDatabase を用意し、teardown で base ごと削除する。
    /// db のみ要るテストは戻り値の `.db` だけ使えばよい（root / tmp の空ディレクトリ作成は無害）。
    func makeTideTestEnv(prefix: String) throws
        -> (db: LocalDatabase, store: TransferStateStore, root: URL, tmp: URL, base: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("root", isDirectory: true)
        let tmp = base.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let db = try LocalDatabase(at: base.appendingPathComponent("db.sqlite"))
        return (db, TransferStateStore(db: db), root, tmp, base)
    }
}

// 以下は self を捕捉しない非同期ヘルパ。@MainActor テスト（SyncActivityModelTests）から
// await で呼んでも非 Sendable な self を送らずに済むよう、メソッドではなく自由関数にする。

/// path が属するシャードの shard_state 行を seed する（ManifestReader が fetch 時点で記録する状況の模擬）。
func seedShardState(db: LocalDatabase, path: String, etag: String) async throws {
    try await db.pool.write { dbq in
        var rec = ShardStateRecord(
            shardId: ManifestSharding.shardId(for: path),
            etag: etag,
            fetchedAt: Date().timeIntervalSince1970
        )
        try rec.save(dbq)
    }
}

/// path が属するシャードの記録 etag を読み出す（無ければ nil）。
func shardEtag(db: LocalDatabase, path: String) async throws -> String? {
    try await db.pool.read { dbq in
        try ShardStateRecord.fetchOne(dbq, key: ManifestSharding.shardId(for: path))?.etag
    }
}

/// type を巡回しながら n 件の sync_log を積む（timestamp は挿入順に増加）。
func seedLogs(_ db: LocalDatabase, count: Int, types: [SyncLogEventType] = [.upload]) async throws {
    try await db.pool.write { dbq in
        for i in 0..<count {
            var row = SyncLogRecord(
                id: nil,
                timestamp: 1000.0 + Double(i),
                eventType: types[i % types.count].rawValue,
                path: "f\(i).txt",
                message: "m\(i)",
                details: nil
            )
            try row.insert(dbq)
        }
    }
}

/// テスト用の決定的データ生成。
enum TestData {
    /// 決定的で非自明なバイト列（全部同じバイトだと連結検証が緩くなるため）。`salt` で内容をずらす。
    static func deterministicBytes(_ count: Int, salt: UInt8 = 0) -> Data {
        Data((0..<count).map { UInt8(($0 + Int(salt)) % 251) })
    }

    /// Data の SHA-256 hex（小文字）。
    static func shaHex(_ data: Data) -> String { HashCalculator.hex(SHA256.hash(data: data)) }
}
