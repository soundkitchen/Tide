import Foundation

/// FP 拡張の小さな相対パス集合を永続化する汎用レジストリ（M5 Phase 5-4・actor）。
/// 用途は構築側がファイル名で分ける（`ExtensionServices` 参照）:
///
/// 1. **仮想フォルダ**（createItem で仮想受理した = マニフェスト非表現の空フォルダ）の温存範囲。
///    `item(for:)` / enumerator が合成 dir を返してよいのを登録済みパスだけに限定する —
///    無条件合成だと dir move の reconcile 中の照会で、消えたはずの旧 dir が空フォルダとして
///    ローカル復活する（5-4 実機 PoC で確定・2026-07-09）。
/// 2. **除外後始末（exclusion cleanup）の予約**。`ExcludedFromSync` を返した path を登録し、
///    システムが後追いで発行する deleteItem（その baseVersion は sha 形でないことを実機観測 =
///    ローカル保留変更の版スタンプとみられる）を「ツリー現行 sha をベースにした RMW ガード付き
///    削除」として受理する根拠にする。除外の後始末以外の deleteItem は従来どおり
///    itemVersion 由来ベースで裁く（「根拠なしに消さない」の維持）。
///
/// - 置き場: App Group Caches（世代ログと同格・bucket キー・factoryReset / `make reset` の
///   掃除範囲）。書き手は FP 拡張プロセスのみ（アクター直列化・atomic 書出・保存失敗は
///   ベストエフォート = ログのみ）。
/// - 読込時にも `validateRelativePath` を再適用する（ディスク上のファイルはプロセス外で
///   改ざん/破損しうる = 世代ログと同じ規約・security/low.md L16）。壊れ / bucket 不一致 /
///   不正パス混入は**全体破棄** = 空集合。失うのは空フォルダの温存保証だけで、同期の正しさ
///   には影響しない（デーモンに掃除され得るのは未実体化の空フォルダのみ）。
/// - 上限 `maxEntries`: 超過 add は無視（notice ログ）。溢れた分は温存保証を失うだけ（安全側）。
public actor PersistedPathSet {
    public static let maxEntries = 1_000
    private static let currentSchemaVersion = 1

    struct Payload: Codable {
        var schemaVersion: Int
        var bucket: String
        var paths: [String]
    }

    private let bucket: String
    private let fileURL: URL?
    private var paths: Set<String> = []
    private var loaded = false

    /// - Parameter fileURL: nil = 永続化なし（構築失敗時の縮退。プロセス生存中のみ有効）。
    public init(bucket: String, fileURL: URL?) {
        self.bucket = bucket
        self.fileURL = fileURL
    }

    /// 永続ファイルの既定 URL（App Group コンテナ内 `Library/Caches/Tide/`・用途別ファイル名）。
    public static func defaultURL(filename: String) throws -> URL {
        let dir = try TideAppGroup.cachesDirectoryURL()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(filename)
    }

    public func contains(_ path: String) -> Bool {
        loadIfNeeded()
        return paths.contains(path)
    }

    public func add(_ path: String) {
        loadIfNeeded()
        guard !paths.contains(path) else { return }
        guard paths.count < Self.maxEntries else {
            AppLogger.fileProvider.notice("persisted path set full; new entry dropped (preservation/cleanup guarantee lost for it)")
            return
        }
        paths.insert(path)
        persist()
    }

    /// path 自身と配下のエントリをまとめて外す（dir 削除 / 除外化）。
    public func removeSubtree(at path: String) {
        loadIfNeeded()
        let prefix = path + "/"
        let next = paths.filter { $0 != path && !$0.hasPrefix(prefix) }
        if next.count != paths.count {
            paths = next
            persist()
        }
    }

    /// subtree ごと rename（仮想フォルダ自身の rename と、実体 dir move に巻き込まれた
    /// 仮想サブフォルダの追従の両方をこれで賄う）。
    public func renameSubtree(from: String, to: String) {
        loadIfNeeded()
        let prefix = from + "/"
        var changed = false
        var next: Set<String> = []
        for p in paths {
            if p == from {
                next.insert(to)
                changed = true
            } else if p.hasPrefix(prefix) {
                next.insert(to + "/" + p.dropFirst(prefix.count))
                changed = true
            } else {
                next.insert(p)
            }
        }
        if changed {
            paths = next
            persist()
        }
    }

    /// ファイル実体化に伴う祖先の掃除: `filePath` にファイルが書かれた = 祖先 dir は
    /// マニフェストの合成 dir になった（レジストリ保護が不要になった）ので外す。
    /// 残しておくと「実体化後にリモートで削除された dir」を空フォルダとして復活させてしまう。
    public func removeAncestors(of filePath: String) {
        loadIfNeeded()
        var ancestor = ""
        var changed = false
        for component in filePath.split(separator: "/").dropLast() {
            ancestor = ancestor.isEmpty ? String(component) : "\(ancestor)/\(component)"
            if paths.remove(ancestor) != nil { changed = true }
        }
        if changed { persist() }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.schemaVersion == Self.currentSchemaVersion,
              payload.bucket == bucket
        else { return }
        var validated: Set<String> = []
        for path in payload.paths {
            guard (try? PathValidator.validateRelativePath(path)) != nil else {
                // 1 件でも不正なら全体破棄（世代ログと同じ姿勢。失うのは温存保証のみ）
                AppLogger.fileProvider.error("persisted path set rejected: unsafe persisted path")
                return
            }
            validated.insert(path)
        }
        paths = validated
    }

    private func persist() {
        guard let fileURL else { return }
        let payload = Payload(
            schemaVersion: Self.currentSchemaVersion, bucket: bucket, paths: paths.sorted())
        do {
            try JSONEncoder().encode(payload).write(to: fileURL, options: .atomic)
        } catch {
            AppLogger.fileProvider.error("persisted path set save failed: \(String(describing: error), privacy: .private)")
        }
    }
}
