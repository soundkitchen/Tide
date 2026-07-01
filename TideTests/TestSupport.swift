import XCTest
import CryptoKit
import TideCore
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

/// 親ディレクトリを作ってから temp syncRoot 配下にファイルを書く（配線テスト共通）。
@discardableResult
func writeFile(_ root: URL, _ relative: String, _ data: Data) throws -> URL {
    let url = root.appendingPathComponent(relative)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
    return url
}

/// path の FileRecord を取得（無ければ nil）。
func fetchFileRecord(_ db: LocalDatabase, path: String) async throws -> FileRecord? {
    try await db.pool.read { db in try FileRecord.fetchOne(db, key: path) }
}

/// FileRecord をシードする（追跡済みファイルの想定）。mtime / etag / versionId / updatedAt /
/// lastSyncedAt はデフォルト引数で、配線テスト 3 スイートが同一の基準フィクスチャを共有する
/// （別設定でシードして暗黙に食い違うのを防ぐ・PR #42 レビュー nit）。
func seedFileRecord(
    _ db: LocalDatabase, path: String, sha: String, size: Int64,
    mtime: Double = 1_780_000_000.5, etag: String = "etag-base",
    versionId: String? = "ver-base", updatedAt: Double = 1_780_000_000,
    lastSyncedAt: Double? = 1_780_000_000
) async throws {
    try await db.pool.write { db in
        var rec = FileRecord(
            path: path, size: size, mtime: mtime, sha256: sha,
            s3VersionId: versionId, s3Etag: etag, lastSyncedAt: lastSyncedAt, updatedAt: updatedAt
        )
        try rec.save(db)
    }
}

/// 値として用意した FileRecord を永続化する（`existing` 引数と DB を意図的に食い違わせる CAS テスト用）。
func saveFileRecord(_ db: LocalDatabase, _ rec: FileRecord) async throws {
    try await db.pool.write { db in var r = rec; try r.save(db) }
}

/// テスト用 Downloader。download を呼ばない経路（削除等）はダミークライアントでよい。
/// 3 スイートで同一構成の Downloader を使うための単一構築点（PR #42 レビュー nit）。
func makeTestDownloader(
    client: any RangedDownloadClient = FakeRangedDownloadClient(fullData: Data()),
    db: LocalDatabase, syncRoot: URL, tmpDir: URL, store: TransferStateStore, deviceId: String = "devL"
) -> Downloader {
    Downloader(downloadClient: client, db: db, syncRoot: syncRoot, tmpDir: tmpDir, deviceId: deviceId, transferStore: store)
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
