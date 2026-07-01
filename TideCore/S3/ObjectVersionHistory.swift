import Foundation

/// 1 つの相対パス（S3 key から `files/` を剥がしたもの）に紐づく 1 バージョン。
/// 実体版（`isDeleteMarker == false`）と delete marker（`true`）の両方をこの型で表す。
public struct FileVersion: Sendable, Identifiable, Equatable, Codable {
    /// バージョン ID。バージョニング無効バケットの "null" もそのまま保持する。
    public let versionId: String?
    /// 実体版のサイズ（バイト）。delete marker は nil。
    public let size: Int64?
    /// S3 が記録した最終更新時刻。
    public let lastModified: Date?
    /// クォート除去済み ETag。delete marker は nil。
    public let etag: String?
    /// この版が現在の最新（current version）か。
    public let isLatest: Bool
    /// delete marker なら true（= この時点でファイルが「削除された」ことを表す）。
    public let isDeleteMarker: Bool

    public var id: String { versionId ?? "null" }

    public init(versionId: String?, size: Int64?, lastModified: Date?, etag: String?, isLatest: Bool, isDeleteMarker: Bool) {
        self.versionId = versionId
        self.size = size
        self.lastModified = lastModified
        self.etag = etag
        self.isLatest = isLatest
        self.isDeleteMarker = isDeleteMarker
    }
}

/// 1 つの相対パスに対するバージョン群（実体版 + delete marker）を**時系列降順（新しい順）**でまとめたもの。
public struct FileVersionHistory: Sendable, Identifiable, Equatable, Codable {
    /// `files/` を剥がし `PathValidator` を通した相対パス（POSIX）。
    public let relativePath: String
    /// 時系列降順（先頭が最新）。
    public let versions: [FileVersion]

    public var id: String { relativePath }

    /// 最新エントリが delete marker なら「現在削除済み」。
    public var isDeleted: Bool { versions.first?.isDeleteMarker ?? false }

    /// 復元可能な実体版（delete marker でない最新の版）。
    /// 削除済みなら delete marker 直前の実体版、現存ファイルなら現行版を指す。
    public var latestRestorableVersion: FileVersion? { versions.first { !$0.isDeleteMarker } }

    public init(relativePath: String, versions: [FileVersion]) {
        self.relativePath = relativePath
        self.versions = versions
    }
}

/// `ListObjectVersions` の生ページ（`TideS3Client.S3ObjectVersionRaw` / `S3DeleteMarkerRaw`）を、
/// 相対パスごとのバージョン履歴へ整形する純粋ロジック。副作用ゼロ・全分岐を `ObjectVersionHistoryTests` で固定する
/// （`ThreeWayMerge` / `ChangeDetector` / `PartPlan` と同じ「純粋 enum + static + 全分岐テスト」パターン）。
///
/// 不正キー（`files/` プレフィックスを持たない / 剥がすと空 / `PathValidator.validateRelativePath` に通らない）は
/// 履歴から除外する（リモートデータ由来の防御。`ManifestReader` と同じ姿勢）。
public enum ObjectVersionHistory {
    /// バージョン本体の S3 key プレフィックス（`Uploader` / `Downloader` の `files/<相対パス>` と一致）。
    public static let filesPrefix = "files/"

    /// S3 key から `keyPrefix` を剥がして相対パスへ正規化する。
    /// プレフィックス不一致 / 空 / `PathValidator` 不合格は nil（= 履歴から除外）。
    public static func relativePath(fromKey key: String, keyPrefix: String = filesPrefix) -> String? {
        guard key.hasPrefix(keyPrefix) else { return nil }
        let rel = String(key.dropFirst(keyPrefix.count))
        guard !rel.isEmpty else { return nil }
        do {
            try PathValidator.validateRelativePath(rel)
        } catch {
            return nil
        }
        return rel
    }

    /// `keyPrefix` 配下の版・delete marker を相対パスごとにグルーピングし、各群を時系列降順に並べる。
    /// 戻り値は相対パスの昇順（決定的）。
    public static func group(
        versions: [TideS3Client.S3ObjectVersionRaw],
        deleteMarkers: [TideS3Client.S3DeleteMarkerRaw],
        keyPrefix: String = filesPrefix
    ) -> [FileVersionHistory] {
        var byPath: [String: [FileVersion]] = [:]

        for v in versions {
            guard let rel = relativePath(fromKey: v.key, keyPrefix: keyPrefix) else { continue }
            byPath[rel, default: []].append(FileVersion(
                versionId: v.versionId,
                size: v.size,
                lastModified: v.lastModified,
                etag: v.etag,
                isLatest: v.isLatest,
                isDeleteMarker: false
            ))
        }
        for m in deleteMarkers {
            guard let rel = relativePath(fromKey: m.key, keyPrefix: keyPrefix) else { continue }
            byPath[rel, default: []].append(FileVersion(
                versionId: m.versionId,
                size: nil,
                lastModified: m.lastModified,
                etag: nil,
                isLatest: m.isLatest,
                isDeleteMarker: true
            ))
        }

        return byPath
            .map { rel, vers in
                FileVersionHistory(relativePath: rel, versions: vers.sorted(by: orderedNewerFirst))
            }
            .sorted { $0.relativePath < $1.relativePath }
    }

    /// 現在削除済み（最新が delete marker）かつ復元可能な実体版を持つファイルだけを返す。
    /// delete marker しか存在しない（復元先が無い）key は除外する。
    public static func deletedFiles(_ histories: [FileVersionHistory]) -> [FileVersionHistory] {
        histories.filter { $0.isDeleted && $0.latestRestorableVersion != nil }
    }

    /// 群内の並び順: 最終更新の降順（新しい順）。nil 時刻は末尾。同時刻は isLatest を先頭、最後に versionId で安定化。
    public static func orderedNewerFirst(_ a: FileVersion, _ b: FileVersion) -> Bool {
        if let la = a.lastModified, let lb = b.lastModified, la != lb {
            return la > lb
        }
        if a.lastModified != nil && b.lastModified == nil { return true }
        if a.lastModified == nil && b.lastModified != nil { return false }
        if a.isLatest != b.isLatest { return a.isLatest }
        return (a.versionId ?? "") > (b.versionId ?? "")
    }
}
