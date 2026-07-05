import Foundation

/// `ManifestUpdater` がマニフェスト（index + シャード）を読み書きするための最小シーム
/// （テスト差し替え用。読み側の `ManifestSnapshotSource` と同じ流儀）。
///
/// M5 Phase 5-0 で導入。`ManifestUpdater` はアプリ（Uploader 経由）と File Provider 拡張の
/// 両方が使う「マニフェスト書込の唯一のチョークポイント」なので、その入出力をこの
/// プロトコル 1 枚で差し替え可能にし、`InMemoryManifestStore`（TideTests）で
/// 楽観ロック（ifMatch/412）を含む全分岐を回帰固定する。
public protocol ManifestStore: Sendable {
    func getIndex() async throws -> TideS3Client.ManifestFetch<ManifestIndex>?
    /// - Returns: 書き込んだオブジェクトの新 etag。
    func putIndex(_ index: ManifestIndex, ifMatch: String?) async throws -> String
    func getShard(_ id: String) async throws -> TideS3Client.ManifestFetch<ManifestShard>?
    /// - Returns: 書き込んだオブジェクトの新 etag。
    func putShard(_ shard: ManifestShard, ifMatch: String?) async throws -> String
    func deleteShard(_ id: String) async throws
}

extension TideS3Client: ManifestStore {}
