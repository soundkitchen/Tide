import Foundation
import GRDB

// MARK: - 値型

/// 完了済みパート 1 つ分（マルチパート再開のチェックポイント単位）。JSON で `completed_parts` に直列化する。
struct CompletedPart: Codable, Sendable, Equatable {
    let n: Int        // パート番号（1 始まり）
    let etag: String
}

/// アップロード（マルチパート）再開に必要な永続状態。
struct UploadResumeState: Sendable, Equatable {
    var uploadId: String
    var partSize: Int
    var completedParts: [CompletedPart]
    /// 再開時にローカルファイルが変わっていないか照合するスナップショット。
    var fileMtime: Double
    var fileSize: Int64
}

/// ダウンロード（Range）再開に必要な永続状態。
struct DownloadResumeState: Sendable, Equatable {
    var tmpPath: String
    var bytesDone: Int64
    /// リモートオブジェクトが変わっていないかの検証（変われば破棄してフル再取得）。
    var expectedEtag: String?
}

/// 転送方向。`transfer_state.direction` の raw 値。
enum TransferDirection: String, Sendable {
    case upload
    case download
}

// MARK: - プロトコルシーム

/// `transfer_state` への型付きアクセス。中断・再開ロジック（D2 アップロード / D3 ダウンロード）が
/// テストでフェイクを差し込めるようプロトコルシームにする（`MultipartUploadClient` と同じ流儀）。
protocol TransferStateStoring: Sendable {
    // アップロード（マルチパート）
    func loadUpload(path: String) async throws -> UploadResumeState?
    func beginUpload(path: String, uploadId: String, partSize: Int, fileMtime: Double, fileSize: Int64) async throws
    func recordCompletedPart(path: String, part: CompletedPart) async throws
    func clearUpload(path: String) async throws

    // ダウンロード（Range）
    func loadDownload(path: String) async throws -> DownloadResumeState?
    func beginDownload(path: String, tmpPath: String, expectedEtag: String?) async throws
    func recordDownloadProgress(path: String, bytesDone: Int64) async throws
    func clearDownload(path: String) async throws

    /// 全行（起動時のオーファン掃除・introspection 用）。
    func allEntries() async throws -> [TransferStateRecord]
}

// MARK: - GRDB 実装

/// `LocalDatabase` を裏に持つ実装。読み出し-変更-書き戻しは GRDB の単一ライタトランザクション内で
/// 行うので、並列の `recordCompletedPart`（有界並列パートアップロードから呼ばれる）でも直列化される。
struct TransferStateStore: TransferStateStoring {
    let db: LocalDatabase

    // MARK: completed_parts の JSON 直列化

    private static func encodeParts(_ parts: [CompletedPart]) -> String {
        guard let data = try? JSONEncoder().encode(parts),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    private static func decodeParts(_ s: String?) -> [CompletedPart] {
        guard let s, let data = s.data(using: .utf8),
              let parts = try? JSONDecoder().decode([CompletedPart].self, from: data) else { return [] }
        return parts
    }

    private static func filter(_ path: String, _ direction: TransferDirection) -> QueryInterfaceRequest<TransferStateRecord> {
        TransferStateRecord
            .filter(Column("path") == path && Column("direction") == direction.rawValue)
    }

    // MARK: - アップロード

    func loadUpload(path: String) async throws -> UploadResumeState? {
        try await db.pool.read { db in
            guard let rec = try Self.filter(path, .upload).fetchOne(db),
                  let uploadId = rec.uploadId,
                  let partSize = rec.partSize,
                  let mtime = rec.fileMtime,
                  let size = rec.fileSize
            else { return nil }
            return UploadResumeState(
                uploadId: uploadId,
                partSize: partSize,
                completedParts: Self.decodeParts(rec.completedParts),
                fileMtime: mtime,
                fileSize: size
            )
        }
    }

    func beginUpload(path: String, uploadId: String, partSize: Int, fileMtime: Double, fileSize: Int64) async throws {
        let ts = Date().timeIntervalSince1970
        let emptyParts = Self.encodeParts([])
        try await db.pool.write { db in
            // (path, upload) を作り直す（再開不能になった旧セッションは上書きで捨てる）。
            _ = try Self.filter(path, .upload).deleteAll(db)
            var rec = TransferStateRecord(
                path: path,
                direction: TransferDirection.upload.rawValue,
                uploadId: uploadId,
                partSize: partSize,
                completedParts: emptyParts,
                tmpPath: nil,
                bytesDone: nil,
                expectedEtag: nil,
                fileMtime: fileMtime,
                fileSize: fileSize,
                updatedAt: ts
            )
            try rec.insert(db)
        }
    }

    func recordCompletedPart(path: String, part: CompletedPart) async throws {
        let ts = Date().timeIntervalSince1970
        try await db.pool.write { db in
            // begin されていなければ no-op（防御的）。
            guard var rec = try Self.filter(path, .upload).fetchOne(db) else { return }
            var parts = Self.decodeParts(rec.completedParts)
            // 同一パート番号は重複させない（パート単位リトライや再送で冪等に保つ）。
            if !parts.contains(where: { $0.n == part.n }) {
                parts.append(part)
            }
            rec.completedParts = Self.encodeParts(parts)
            rec.updatedAt = ts
            try rec.update(db)
        }
    }

    func clearUpload(path: String) async throws {
        try await db.pool.write { db in
            _ = try Self.filter(path, .upload).deleteAll(db)
        }
    }

    // MARK: - ダウンロード

    func loadDownload(path: String) async throws -> DownloadResumeState? {
        try await db.pool.read { db in
            guard let rec = try Self.filter(path, .download).fetchOne(db),
                  let tmpPath = rec.tmpPath,
                  let bytes = rec.bytesDone
            else { return nil }
            return DownloadResumeState(
                tmpPath: tmpPath,
                bytesDone: bytes,
                expectedEtag: rec.expectedEtag
            )
        }
    }

    func beginDownload(path: String, tmpPath: String, expectedEtag: String?) async throws {
        let ts = Date().timeIntervalSince1970
        try await db.pool.write { db in
            _ = try Self.filter(path, .download).deleteAll(db)
            var rec = TransferStateRecord(
                path: path,
                direction: TransferDirection.download.rawValue,
                uploadId: nil,
                partSize: nil,
                completedParts: nil,
                tmpPath: tmpPath,
                bytesDone: 0,
                expectedEtag: expectedEtag,
                fileMtime: nil,
                fileSize: nil,
                updatedAt: ts
            )
            try rec.insert(db)
        }
    }

    func recordDownloadProgress(path: String, bytesDone: Int64) async throws {
        let ts = Date().timeIntervalSince1970
        try await db.pool.write { db in
            guard var rec = try Self.filter(path, .download).fetchOne(db) else { return }
            rec.bytesDone = bytesDone
            rec.updatedAt = ts
            try rec.update(db)
        }
    }

    func clearDownload(path: String) async throws {
        try await db.pool.write { db in
            _ = try Self.filter(path, .download).deleteAll(db)
        }
    }

    // MARK: - 全行

    func allEntries() async throws -> [TransferStateRecord] {
        try await db.pool.read { db in
            try TransferStateRecord.fetchAll(db)
        }
    }
}
