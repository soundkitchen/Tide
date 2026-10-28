import Foundation

/// File Provider 書込経路（M5 Phase 5-2）の純粋判定。FP の型には依存しない
/// （Data / String のみ受ける）— `TideFileProvider` ターゲットは TideTests から import
/// できないため、テスト可能なロジックは TideCore に置く。
public enum FileProviderWritePolicy {
    /// `NSFileProviderItemVersion.contentVersion` に載せるバイト列をノードから作る。
    /// file = sha256 hex（小文字）の UTF-8 / directory = `"dir"` の UTF-8。
    /// **符号化（これ）と復号（`baseSha`）を対で同居させる**（PR #58 レビュー #8）: 別モジュールに
    /// 分かれていると Phase 5-3/5-4 で片方だけ変えたとき、コンパイルもテストも通らないまま
    /// 「全 delete が拒否 / 全 modify が base:nil 劣化」の無言故障になる。往復は
    /// `FileProviderWritePolicyTests` が固定する。
    public static func contentVersion(for node: ManifestTree.Node) -> Data {
        switch node {
        case .file(_, let entry): return Data(entry.sha256.utf8)
        case .directory: return Data("dir".utf8)
        }
    }

    /// 実体化バッジ（Issue #65）: `metadataVersion` に実体化フラグを織り込む複合符号化のサフィックス。
    /// **contentVersion には絶対に付けない** — contentVersion の変化は「内容が変わった」の意味に
    /// なり再取得を誘発する。バッジはメタデータ変化としてだけ届ける。
    public static let materializedSuffix = "|m"

    /// `NSFileProviderItemVersion.metadataVersion` に載せるバイト列（Issue #65 で複合符号化に拡張）。
    /// - file = sha256（+ 実体化時 `|m`）。**sha プレフィックスは rebind 対応の load-bearing**
    ///   （rebind 後の操作は contentVersion がローカル版スタンプに差し替わるため、`baseSha` が
    ///   metadataVersion 側から 3-way ベースを復元する。M5 Phase 5-4）。
    /// - directory = `dir-<ISO8601 mtime>` / `dir`（+ 実体化時 `|m`）。dir は `baseSha` の対象外
    ///   なので符号化自体に rebind 制約は無い。
    public static func metadataVersion(for node: ManifestTree.Node, materialized: Bool) -> Data {
        let base: String
        switch node {
        case .file(_, let entry):
            base = entry.sha256
        case .directory(_, let mtime):
            base = mtime.map { "dir-\(ISO8601.format($0))" } ?? "dir"
        }
        return Data((materialized ? base + Self.materializedSuffix : base).utf8)
    }

    /// FP の `NSFileProviderItemVersion.contentVersion` の中身から 3-way ベースの sha256 を
    /// 取り出す（`contentVersion(for:)` の逆写像 + 防御的検証）。
    /// - "dir" / 非 UTF-8 / 空 / sha256 hex（64 桁小文字）以外 → nil = 内容ベース不明。
    ///   nil の扱いは呼び出し側の意味論に委ねる（削除ガードは「根拠なしに消さない」= 拒否側、
    ///   アップロード競合判定は `decideUpload(base: nil)` = remote 有りなら競合側、へ倒れる）。
    /// - 実体化バッジの複合符号化（`<sha>|m`・metadataVersion 経由で届く）は剥がしてから検証する。
    ///   既知のサフィックス以外の付加は従来どおり不正として弾く。なお `|m` は metadataVersion に
    ///   しか発行しないため contentVersion 位置での剥がしは厳密には過剰受理だが、両 version を
    ///   同一デコーダで裁く単純さを優先する（64-hex 検証は維持・PR #66 レビュー nit 2 の記録）。
    public static func baseSha(fromContentVersion data: Data?) -> String? {
        guard let data, var s = String(data: data, encoding: .utf8) else { return nil }
        if s.hasSuffix(Self.materializedSuffix) {
            s = String(s.dropLast(Self.materializedSuffix.count))
        }
        guard s.count == 64,
              s.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else {
            return nil
        }
        return s
    }

    /// `NSFileProviderItemVersion` の contentVersion / metadataVersion の両方から 3-way ベースを
    /// 復元する（M5 Phase 5-4）。**metadataVersion フォールバックの理由**: rebind（modifyItem の
    /// 返却 item で id を変えた move）で生まれた item への次操作は、システムが渡す baseVersion の
    /// contentVersion が sha 形でない（ローカル保留変更の版スタンプとみられる・実機確定）。
    /// Tide の file item は metadataVersion == contentVersion（同じ sha）で発行しているため、
    /// metadataVersion 側から復元できれば本来のベースガードがそのまま機能する。
    /// 両方 nil = 本当にベース不明（呼び出し側の拒否側ポリシーへ）。
    public static func baseSha(contentVersion: Data?, metadataVersion: Data?) -> String? {
        baseSha(fromContentVersion: contentVersion)
            ?? baseSha(fromContentVersion: metadataVersion)
    }

    /// rename/reparent 後の版スタンプ自動治癒（Issue #93）の対象選定。move された各ファイル
    /// （from = 旧相対パス, to = 新相対パス）のうち、**実体化済みのものだけ**を治癒対象
    /// （`reimportItems(below:)` を要求する新パス）として返す。
    /// - 実体化ゲートの理由: dataless ファイルは症状（バッジとクラウドアイコンの併存）が
    ///   可視化されず、次の materialize（fetchContents）で自然に再刻印されるため治癒不要
    ///   （ユーザ確定 2026-08-25）。
    /// - `materialized` は from / to どちらの掲載でも実体化とみなす: 観測タイミングにより
    ///   旧パス集合（rebind 前の live / renameSubtree 前の reported）と新パス集合
    ///   （rebind 後 / renameSubtree 後）のどちらを見るかが揺れるため、両建てで取りこぼしを防ぐ。
    /// - 順序は入力順を保持（dir move の複数ファイルでログ・リトライの追跡がしやすい）。
    public static func moveRestampTargets(
        moves: [(from: String, to: String)], materialized: Set<String>
    ) -> [String] {
        moves.filter { materialized.contains($0.from) || materialized.contains($0.to) }
            .map(\.to)
    }

    /// createItem（M5 Phase 5-3）の「親ディレクトリ相対パス + filename」→ 相対 POSIX パス。
    /// filename はデーモン供給値だがパス合成の入口なので構造的に検証する:
    /// 空 / "." / ".." / `/` 含み（ネスト注入）/ NUL 含みは nil = 合成不能。
    /// フルパスとしての妥当性（バックスラッシュ・トラバーサル等の網羅検証）は呼び出し側が
    /// `PathValidator.validateRelativePath` で担う（この関数は filename 起因の構造破壊のみ塞ぐ）。
    /// `/` と NUL は UTF-8 バイト単位で探す（#137）。`String.contains` は書記素単位なので、
    /// `/` の直後に結合文字が付くと見落とす。
    public static func childPath(parentPath: String, filename: String) -> String? {
        guard !filename.isEmpty, filename != ".", filename != "..",
              !filename.utf8.contains(UInt8(ascii: "/")), !filename.utf8.contains(0) else {
            return nil
        }
        return parentPath.isEmpty ? filename : "\(parentPath)/\(filename)"
    }

    /// 通知や記録に出す表示用のパス（Issue #147）。`childPath` と違って検証しない — 同期できない
    /// 名前もそのまま組み立てる（表示専用・FS 操作にも S3 キーにも使わない）。通知の重複除去の鍵にも
    /// なるので、createItem と modifyItem で同じ式を使うためにここへ置く。
    public static func displayPath(parentPath: String, filename: String) -> String {
        parentPath.isEmpty ? filename : "\(parentPath)/\(filename)"
    }

    /// フォルダの deleteItem の進め方（M5 Phase 5-3・#120 レビュー B1）。
    public enum DirectoryDeletePlan: Equatable, Sendable {
        /// S3 に触れず、ローカル側の掃除（仮想フォルダ登録など）だけで成功を返す
        case localOnly
        /// 非再帰の削除で中身がある → DirectoryNotEmpty（SDK 契約）
        case notEmpty
        /// 配下の追跡済みファイルを S3 から消す（RMW ガード付き）
        case deleteRemote
    }

    /// フォルダの deleteItem を S3 へ伝えるかを決める。
    /// - `hasExclusionHold`: そのフォルダ（か祖先）を「追跡ゼロを根拠にフォルダ単位で除外した」
    ///   予約がある。後始末の deleteItem は判定時点から数十分遅れて届くことがあり（#120 実機）、
    ///   その間に他端末が配下へ上げたファイルを消さないよう、**予約があれば追跡数に関わらず
    ///   S3 非接触**にする（除外はローカル温存の意味論 = ユーザは削除を意図していない）。
    public static func directoryDeletePlan(
        trackedCount: Int, hasExclusionHold: Bool, recursive: Bool
    ) -> DirectoryDeletePlan {
        if hasExclusionHold || trackedCount == 0 { return .localOnly }
        return recursive ? .deleteRemote : .notEmpty
    }

    /// rename / reparent のコピー元の切り替え（#130）: 宣言版（`entry.s3VersionId`）が失効して
    /// コピーできなかったとき、代わりに使ってよい最新版の versionId を返す。使えなければ nil。
    /// 最新版の ETag とサイズが entry と一致する（= 中身が同じ）ときだけ切り替える。コピーは
    /// 内容を検証できないので、一致を確かめずに最新版へ倒すと「宣言 sha と実体が乖離した entry」を
    /// 作り得る（`S3Client.copyObject` の規約）。ETag は SSE-S3 の単発 PUT なら内容の MD5、
    /// マルチパートなら各パートの MD5 から作る値で、どちらも内容が違えば一致しない。
    /// - 最新版の versionId が無い / 宣言版と同じ（= 同じ版の再試行で切り替えにならない）は nil。
    public static func copySourceFallbackVersion(
        entry: ManifestFileEntry, latestEtag: String, latestVersionId: String?, latestSize: Int64?
    ) -> String? {
        guard let latestVersionId, latestVersionId != entry.s3VersionId else { return nil }
        guard !latestEtag.isEmpty, latestEtag == entry.etag, latestSize == entry.size else { return nil }
        return latestVersionId
    }

    /// パス自身と祖先（深い → 浅い順・ルート "" は含まない）。`a/b/c` → `[a/b/c, a/b, a]`。
    /// 除外の予約は除外したフォルダの path で積まれるが、後始末の deleteItem は配下の
    /// 仮想フォルダ（以前に受理済みの `d:` item）単位でも届くため、祖先まで照合する。
    public static func pathAndAncestors(_ path: String) -> [String] {
        var result: [String] = []
        var current = Substring(path)
        while !current.isEmpty {
            result.append(String(current))
            guard let slash = current.lastIndex(of: "/") else { break }
            current = current[..<slash]
        }
        return result
    }
}
