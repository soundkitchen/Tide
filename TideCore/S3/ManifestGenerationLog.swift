import Foundation

/// File Provider 拡張の増分列挙（M5 Phase 4）を支える、マニフェストスナップショットの
/// **世代ログ**。`NSFileProviderSyncAnchor` ↔ 世代（anchor 文字列）を対応させ、
/// `enumerateChanges(from:)` が「システムが最後に見た世代 → 現在」の diff を計算できるよう、
/// 直近 `maxGenerations` 世代のファイルマップを 1 つの JSON に永続化する。
///
/// - **差分で持つ（Issue #128・スキーマ v2）**: 全件のファイルマップを持つのは最新世代だけで、
///   古い世代は「1 つ新しい世代から自分へ戻す逆差分」（`ReverseDelta`）で持つ。v1 は世代ごとに
///   全件を複製しており、追跡 4 万件・8 世代で 135MB・読込 1.2 秒 / ピーク 544MB・保存 2.25 秒 /
///   ピーク約 900MB になっていた（ファイル数 × 世代数に比例）。古い世代は `generation(anchor:in:)`
///   が最新世代から逆差分を順に当てて組み立てる（`enumerateChanges` の diff 起点にだけ使う）。
/// - 書き手は **File Provider 拡張プロセスのみ**（プロセス内はアクターで直列化・atomic 書出）。
///   アプリ本体はこのファイルに触らない。
/// - これは**派生データ**（S3 のマニフェストからいつでも再生成できる）なので App Group
///   コンテナ内の `Library/Caches` に置く。消えても anchor 不明 → `.syncAnchorExpired` →
///   システムが全再列挙して自己回復するだけで実害はない（v1 のログもこの経路で捨てる =
///   更新後に一度だけ全再列挙・2026-10-17 ユーザ確定）。
/// - 中身は相対パスとファイルメタデータのみ（`DeletedFilesCache` と同水準。認証情報・deviceId
///   の秘匿値は含まない — deviceId はマニフェスト由来の書込元表示値で Keychain 秘匿対象ではない）。
public enum ManifestGenerationLog {

    public static let currentSchemaVersion = 2
    /// 保持する世代数（最新世代を含む）。コンテナごとの anchor が数世代ずれても diff を返せる
    /// 程度に持ち、それより古い anchor は `.syncAnchorExpired`（全再列挙）に倒す。
    /// 64（Issue #131・2026-10-17 ユーザ確定。旧 8）: 大量の書込で世代が数秒ごとに進むと、8 世代は
    /// 約 45 秒で入れ替わり、fileproviderd の anchor が失効して全再列挙になるうえ、ページに分けた
    /// 全再列挙（約 3 万件）も固定した世代が先に落ちて終わらなかった。古い世代は逆差分だけを持つ
    /// （#128）ので、増やしても大きさは差分の量にしか比例しない。
    public static let defaultMaxGenerations = 64

    /// 1 世代 = ある時点のリモート全体像。`anchor` が `NSFileProviderSyncAnchor` の中身になる。
    public struct Generation: Codable, Equatable, Sendable {
        public var anchor: String
        public var fetchedAt: Date
        /// shardId → 取得済みオブジェクト etag（次回増分ロードの比較材料）。最新世代の値だけを
        /// 保持し、逆差分から組み立てた古い世代では空（増分ロードの前回値は最新世代しか使わない）。
        public var shardEtags: [String: String]
        public var files: [String: ManifestFileEntry]

        public init(anchor: String, fetchedAt: Date, shardEtags: [String: String], files: [String: ManifestFileEntry]) {
            self.anchor = anchor
            self.fetchedAt = fetchedAt
            self.shardEtags = shardEtags
            self.files = files
        }
    }

    /// 古い世代 1 つ分 = 「1 つ新しい世代のファイルマップ」から自分へ戻す逆差分。
    public struct ReverseDelta: Codable, Equatable, Sendable {
        public var anchor: String
        public var fetchedAt: Date
        /// この世代の entry のうち、1 つ新しい世代では値が違うか無いもの（戻すときに置く）。
        public var restored: [String: ManifestFileEntry]
        /// この世代には無く、1 つ新しい世代で現れたパス（戻すときに消す）。
        public var removed: [String]

        public init(anchor: String, fetchedAt: Date, restored: [String: ManifestFileEntry], removed: [String]) {
            self.anchor = anchor
            self.fetchedAt = fetchedAt
            self.restored = restored
            self.removed = removed
        }

        /// `newer`（1 つ新しい世代）から `older`（この世代）へ戻す逆差分を作る。
        public static func between(
            newer: [String: ManifestFileEntry], older: Generation
        ) -> ReverseDelta {
            var restored: [String: ManifestFileEntry] = [:]
            for (path, entry) in older.files where newer[path] != entry {
                restored[path] = entry
            }
            let removed = newer.keys.filter { older.files[$0] == nil }.sorted()
            return ReverseDelta(
                anchor: older.anchor, fetchedAt: older.fetchedAt,
                restored: restored, removed: removed)
        }

        /// 1 つ新しい世代のファイルマップへ当てて、この世代のファイルマップに戻す。
        public func apply(to files: inout [String: ManifestFileEntry]) {
            for path in removed {
                files.removeValue(forKey: path)
            }
            for (path, entry) in restored {
                files[path] = entry
            }
        }
    }

    /// 永続ファイルの中身（純粋値・テスト可能）。
    public struct Payload: Codable, Equatable, Sendable {
        public var schemaVersion: Int
        /// このログを採った bucket。現在の bucket と不一致なら無効（別バケットの世代で diff しない）。
        public var bucket: String
        /// 最新世代（全件のファイルマップ）。
        public var latest: Generation
        /// 古い世代の逆差分。古い → 新しい順で、末尾が `latest` の 1 つ前の世代。
        public var history: [ReverseDelta]

        public init(schemaVersion: Int, bucket: String, latest: Generation, history: [ReverseDelta]) {
            self.schemaVersion = schemaVersion
            self.bucket = bucket
            self.latest = latest
            self.history = history
        }

        /// 保持している世代の anchor（古い → 新しい順・末尾が最新）。
        public var anchors: [String] {
            history.map(\.anchor) + [latest.anchor]
        }
    }

    public enum LogError: Error {
        case unsupportedVersion(found: Int, supported: Int)
    }

    // MARK: - 純粋ロジック（テスト可能）

    public static func latest(of payload: Payload?) -> Generation? {
        payload?.latest
    }

    /// anchor の世代。古い世代は最新世代から逆差分を新しい順に当てて組み立てる（O(全件) の
    /// 複製を伴うので、diff の起点を求めるときだけ呼ぶ）。見つからなければ nil。
    public static func generation(anchor: String, in payload: Payload?) -> Generation? {
        guard let payload else { return nil }
        if payload.latest.anchor == anchor {
            return payload.latest
        }
        guard let index = payload.history.lastIndex(where: { $0.anchor == anchor }) else {
            return nil
        }
        var files = payload.latest.files
        for delta in payload.history[index...].reversed() {
            delta.apply(to: &files)
        }
        let target = payload.history[index]
        return Generation(
            anchor: target.anchor, fetchedAt: target.fetchedAt, shardEtags: [:], files: files)
    }

    /// 新しいスナップショットをログへ反映する。
    /// - ファイル内容が最新世代と**同一**なら世代を増やさない（anchor 安定）。ただし shard etag と
    ///   取得時刻は最新値で更新する（同内容でシャードが書き直された場合に次回の再取得を避ける）。
    /// - 内容が変わっていれば、旧最新世代を逆差分にして history の末尾へ積み、新世代を最新にする。
    ///   `maxGenerations`（最新を含む）を超えた古い世代は history の先頭から落とす。
    /// - Returns: 更新後 payload と、新世代が追加されたか（= 変更検知。呼び出し側の signal 契機）。
    public static func appending(
        snapshot: ManifestSnapshotLoader.SnapshotResult,
        anchor: String,
        fetchedAt: Date,
        to payload: Payload?,
        bucket: String,
        maxGenerations: Int = defaultMaxGenerations
    ) -> (payload: Payload, appended: Bool) {
        let newGeneration = Generation(
            anchor: anchor, fetchedAt: fetchedAt,
            shardEtags: snapshot.shardEtags, files: snapshot.files)
        guard var next = payload, next.bucket == bucket else {
            return (Payload(
                schemaVersion: currentSchemaVersion, bucket: bucket,
                latest: newGeneration, history: []), true)
        }
        if next.latest.files == snapshot.files {
            next.latest.shardEtags = snapshot.shardEtags
            next.latest.fetchedAt = fetchedAt
            return (next, false)
        }
        next.history.append(ReverseDelta.between(newer: snapshot.files, older: next.latest))
        next.latest = newGeneration
        let keep = max(maxGenerations - 1, 0)
        if next.history.count > keep {
            next.history.removeFirst(next.history.count - keep)
        }
        return (next, true)
    }

    // MARK: - 符号化

    public static func encode(_ payload: Payload) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(payload)
    }

    /// JSON をデコードし、スキーマ版を検証する。新しすぎる/不一致版は `unsupportedVersion`。
    /// v1（世代ごとの全件複製）は形が違うのでデコード自体が失敗する = 読込側で nil（cold）。
    public static func decode(_ data: Data) throws -> Payload {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let payload = try dec.decode(Payload.self, from: data)
        guard payload.schemaVersion == currentSchemaVersion else {
            throw LogError.unsupportedVersion(found: payload.schemaVersion, supported: currentSchemaVersion)
        }
        return payload
    }

    // MARK: - IO（拡張プロセス専用・アクター配下で呼ぶ）

    /// 永続ファイルの既定 URL（App Group コンテナ内 `Library/Caches/Tide/`）。
    /// アプリの `factoryReset` / `make reset` の掃除範囲に含める。
    public static func defaultURL() throws -> URL {
        let dir = try TideAppGroup.cachesDirectoryURL()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("fileprovider-manifest-log.json")
    }

    /// 読込: 欠落 / 壊れ / スキーマ不一致 / bucket 不一致 / 不正パス混入はすべて nil
    /// （ログ無効 = cold 扱い → `.syncAnchorExpired` → 全再列挙で自己回復）。
    ///
    /// パス再検証について: 書込み時のデータは `ManifestSnapshotLoader` の
    /// `validateRelativePath` ゲートを通っているが、**ディスク上のファイルはプロセス外で
    /// 改ざん/破損しうる**ため、読込時にも同じゲートを再適用する。素通りさせると持ち越し経路
    /// （`load(previous:)` は「検証済み」前提で無検証コピー）から不正パスが item identifier と
    /// S3 キー組み立てに到達する（PR #51 レビュー #3・security/low.md L16）。
    ///
    /// history が上限（`maxGenerations - 1`）より長い場合は、古い側から切り詰める（改ざん・破損や、
    /// 将来 `defaultMaxGenerations` を減らした後の旧ログで、組み立てに当てる逆差分の数が上限を
    /// 超えないようにする・PR #129 レビュー N2）。逆差分は新しい世代から順に当てるので、古い側を
    /// 落としても残りの世代は正しく組み立てられる。
    public static func load(
        bucket: String, url: URL, maxGenerations: Int = defaultMaxGenerations
    ) -> Payload? {
        guard let data = try? Data(contentsOf: url),
              var payload = try? decode(data),
              payload.bucket == bucket else { return nil }
        let keep = max(maxGenerations - 1, 0)
        if payload.history.count > keep {
            payload.history.removeFirst(payload.history.count - keep)
        }
        // 最新世代の全件と、逆差分に現れるパス（戻すときに置く / 消す）をすべて検証する。
        // 古い世代はこの 3 種のパスからしか組み立てられないので、これで全世代を覆う。
        func allSafe<S: Sequence>(_ paths: S) -> Bool where S.Element == String {
            paths.allSatisfy { (try? PathValidator.validateRelativePath($0)) != nil }
        }
        guard allSafe(payload.latest.files.keys),
              payload.history.allSatisfy({ allSafe($0.restored.keys) && allSafe($0.removed) })
        else {
            AppLogger.fileProvider.error("Generation log rejected: unsafe path in persisted snapshot")
            return nil
        }
        return payload
    }

    /// 保存: atomic 書き出し。呼び出し側はベストエフォート（失敗はログのみ）で扱う。
    public static func save(_ payload: Payload, url: URL) throws {
        try encode(payload).write(to: url, options: .atomic)
    }
}
