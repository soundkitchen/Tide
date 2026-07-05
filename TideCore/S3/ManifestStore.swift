import Foundation

/// `ManifestUpdater` がマニフェスト（index + シャード）を読み書きするための最小シーム
/// （テスト差し替え用。読み側の `ManifestSnapshotSource` と同じ流儀）。
///
/// M5 Phase 5-0 で導入。`ManifestUpdater` はアプリ（Uploader 経由）と File Provider 拡張の
/// 両方が使う「マニフェスト書込の唯一のチョークポイント」なので、その入出力をこの
/// プロトコル 1 枚で差し替え可能にし、`InMemoryManifestStore`（TideTests）で
/// 楽観ロック（ifMatch/412）を含む全分岐を回帰固定する。
/// 読み側（getIndex / getShard）は既存の `ManifestSnapshotSource` を継承し、宣言の正本を
/// 1 つに保つ（PR #56 レビュー ⑤）。書き側 3 メソッドだけを本プロトコルが足す。
public protocol ManifestStore: ManifestSnapshotSource {
    /// - Returns: 書き込んだオブジェクトの新 etag。
    func putIndex(_ index: ManifestIndex, ifMatch: String?) async throws -> String
    /// - Returns: 書き込んだオブジェクトの新 etag。
    func putShard(_ shard: ManifestShard, ifMatch: String?) async throws -> String
    func deleteShard(_ id: String) async throws
}

extension TideS3Client: ManifestStore {}
