import Foundation

/// File Provider 書込経路（M5 Phase 5-2）の純粋判定。FP の型には依存しない
/// （Data / String のみ受ける）— `TideFileProvider` ターゲットは TideTests から import
/// できないため、テスト可能なロジックは TideCore に置く。
public enum FileProviderWritePolicy {
    /// `NSFileProviderItemVersion.contentVersion` に載せるバイト列をノードから作る。
    /// file = sha256 hex（小文字）の UTF-8 / directory = `"dir"` の UTF-8 /
    /// package = 中身の digest（`ManifestTree.packageDigest`・sha256 と同じ形・#140）の UTF-8。
    /// **符号化（これ）と復号（`baseSha`）を対で同居させる**（PR #58 レビュー #8）: 別モジュールに
    /// 分かれていると Phase 5-3/5-4 で片方だけ変えたとき、コンパイルもテストも通らないまま
    /// 「全 delete が拒否 / 全 modify が base:nil 劣化」の無言故障になる。往復は
    /// `FileProviderWritePolicyTests` が固定する。
    public static func contentVersion(for node: ManifestTree.Node) -> Data {
        switch node {
        case .file(_, let entry): return Data(entry.sha256.utf8)
        case .directory: return Data("dir".utf8)
        case .package(_, _, let digest, _): return Data(digest.utf8)
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
        case .package(_, _, let digest, _):
            // パッケージも digest を先頭に置く（ファイルと同じく rebind 後の 3-way ベースを
            // metadataVersion から復元するため・#140）。
            base = digest
        case .directory(_, let mtime):
            base = mtime.map { "dir-\(ISO8601.format($0))" } ?? "dir"
        }
        return Data((materialized ? base + Self.materializedSuffix : base).utf8)
    }

    /// ディレクトリの `metadataVersion`（`dir-<ISO8601 mtime>`・実体化の `|m` 付きも）から日時を
    /// 取り出す（`metadataVersion(for:)` の dir 側の逆写像・Issue #144）。日時を持たない `"dir"`・
    /// ファイルやパッケージの版・読めない形は nil。
    /// 用途: 仮想フォルダの改名の modifyItem は、システムが渡す item に日時が入っていない
    /// （`changedFields` が名前だけのとき・2026-10-31 実機）。日時なしで返すとシステムが 1970 を
    /// ディスクに書くので、baseVersion に符号化しておいた日時を返す（精度は秒）。
    public static func directoryMtime(fromMetadataVersion data: Data?) -> Date? {
        guard let data, var s = String(data: data, encoding: .utf8) else { return nil }
        if s.hasSuffix(Self.materializedSuffix) {
            s = String(s.dropLast(Self.materializedSuffix.count))
        }
        let prefix = "dir-"
        guard s.hasPrefix(prefix) else { return nil }
        return ISO8601.parse(String(s.dropFirst(prefix.count)))
    }

    /// modifyItem で仮想フォルダを返すときの日時を決める（Issue #144・メタデータ変更と改名で共有）。
    /// 日時なし（nil）で返すとシステムが 1970 をディスクに書くので、できるだけ日時を付ける。
    /// 1. 日時が変わった（`changedFields` に contentModificationDate がある）なら item の日時
    /// 2. そうでなければ前に返した版（baseVersion の metadataVersion = `dir-<日時>`）の日時 —
    ///    `changedFields` に無いフィールドは item に入っている保証が無い（改名・タグだけの変更では
    ///    入っていないことを実機で確認）ので、item の値より版を信じる
    /// 3. 版にも無ければ item の日時（無ければ nil）
    public static func virtualDirectoryMtime(
        dateChanged: Bool, itemDate: Date?, baseMetadataVersion: Data?
    ) -> Date? {
        if dateChanged, let itemDate { return itemDate }
        return directoryMtime(fromMetadataVersion: baseMetadataVersion) ?? itemDate
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

    /// パッケージを書くか（FP の createItem / modifyItem・#140）。
    public enum PackageWriteDecision: Equatable, Sendable {
        /// 書く。`remoteMembers` は今のマニフェストの中身（中身ごとの 3-way のベースと、消す中身の一覧）。
        case write(remoteMembers: [String: ManifestFileEntry])
        /// マニフェストが同じ中身を既に持つ（再取り込みの問い直し・クラッシュ後の再送）= 何も書かない。
        case unchanged
        /// ベースの後でリモートが変わった・新規作成が他の端末の作成と重なった・同じパスに単一ファイルの
        /// 書類がある = 競合コピーへ。
        case conflict
        /// 同じパスにフォルダがある = 名前の衝突（システムに名前をずらさせる）。
        case kindCollision
    }

    /// パッケージの書込の判定（ファイルの `decideUpload` をパッケージの版 = digest で行う）。
    /// - Parameters:
    ///   - localShas: ローカルの中身（パッケージ内の相対パス → sha256）。版はここから出す。
    ///   - base: システムが最後に見た版（新規作成は nil）。
    ///   - remote: 今のツリーのそのパスのノード。
    ///   - replacingFileSha: 書類の形式の切り替え（単一ファイル → パッケージ）で、置き換える旧いファイルの
    ///     sha（ベースと照らし済みのもの）。それ以外は nil。
    ///
    /// 同じパスに**ファイル**があるときは、形式の切り替えで置き換えるそのファイル（sha が
    /// `replacingFileSha` と一致）のときだけ書く（書いた後に呼び出し側がベースつきで消す。それまでは
    /// ツリーでパッケージが勝つ）。それ以外 — 新規作成・`k:` の item の編集で、他の端末がそのパスを
    /// 単一ファイルにしていた — は競合（PR #152 レビュー指摘 2: 書くとファイルの entry がパッケージの
    /// 陰に隠れ、消す deleteItem も来ないまま残って、パッケージを消すと復活する）。リモートに無いときは
    /// 書く（ベースつきなら、リモートの削除よりローカルの編集を残す側 = ファイルと同じ）。
    ///
    /// **新規作成（ベース無し）でリモートが書きかけ**のとき — リモートの中身がすべてローカルにあり
    /// sha256 も一致する — は競合にせず、足りない中身を書き足す（#140 の受け入れで実踏: 改名・移動の
    /// まとめ書きの途中で、返事を失ったシステムがローカルを新規作成として送り直し、途中までしか載って
    /// いないツリーと版が食い違って、中身の同じ競合コピーができた）。リモートにだけある中身や sha の
    /// 食い違いがあれば別の内容 = 従来どおり競合。ベースつき（編集）には当てない — リモートの中身が
    /// 減っているのは他の端末の削除かもしれず、書き足すと消した中身を戻してしまう。
    public static func packageWriteDecision(
        localShas: [String: String], base: String?, remote: ManifestTree.Node?,
        replacingFileSha: String? = nil
    ) -> PackageWriteDecision {
        switch remote {
        case nil:
            return .write(remoteMembers: [:])
        case .file(_, let entry)?:
            return replacingFileSha == entry.sha256 ? .write(remoteMembers: [:]) : .conflict
        case .directory?:
            return .kindCollision
        case .package(_, let members, let digest, _)?:
            if digest == ManifestTree.packageDigest(shas: localShas) { return .unchanged }
            if base == digest { return .write(remoteMembers: members) }
            if base == nil, members.allSatisfy({ localShas[$0.key] == $0.value.sha256 }) {
                return .write(remoteMembers: members)
            }
            return .conflict
        }
    }

    /// 書類の形式の切り替え（#140・Keynote の「ファイルタイプを変更」）の判定。fileproviderd は形式を
    /// 変えた保存を、旧 id の削除 + 新 id の作成ではなく**同じ item の中身が別の形式になった
    /// modifyItem** として送ってくる（2026-10-30 実機）。新しい形式で同じパスに書いてから旧い形式の
    /// entry を消す（途中で止まっても旧い形式が残る側 = ツリーではパッケージが勝つ）。
    public enum FormatChangeDecision: Equatable, Sendable {
        /// パッケージ → 単一ファイル: ファイルを書いてから、この中身（パッケージ内の相対パス → entry）を消す。
        case replacePackage(members: [String: ManifestFileEntry])
        /// 単一ファイル → パッケージ: パッケージを書いてから、この sha のファイルの entry を消す
        /// （nil = 消す根拠が無い = 消さない）。
        case replaceFile(oldSha: String?)
        /// 旧い形式はもう無い・既に新しい形式になっている = 新しい形式で普通に書く（ベース無し）。
        case writeNew
        /// ベースの後でリモートが変わった = ローカルの内容は競合コピーへ・正規パスはリモートのまま。
        case conflict
        /// 同じパスがフォルダ。
        case kindCollision
    }

    /// パッケージ（`k:`）の item に単一ファイルの中身が届いたときの判定。
    /// - Parameters:
    ///   - baseDigest: システムが最後に見たパッケージの版。nil（版の形でない）は根拠が無いので競合側。
    ///   - remote: 今のツリーのそのパスのノード。
    public static func fileReplacingPackageDecision(
        baseDigest: String?, remote: ManifestTree.Node?
    ) -> FormatChangeDecision {
        switch remote {
        case .package(_, let members, let digest, _)?:
            return baseDigest == digest ? .replacePackage(members: members) : .conflict
        case .file?, nil:
            // 切り替え済み（再試行）・他の端末が先にファイルにした・リモートで消えた = ファイルとして
            // ベース無しで書く（同じ内容なら書かない・別の内容なら `decideUpload` が競合にする）。
            return .writeNew
        case .directory?:
            return .kindCollision
        }
    }

    /// 単一ファイル（`f:`）の item にパッケージの中身が届いたときの判定。
    /// - Parameters:
    ///   - baseSha: システムが最後に見たファイルの sha。nil（版の形でない）は根拠が無いので競合側。
    ///   - remote: 今のツリーのそのパスのノード。
    public static func packageReplacingFileDecision(
        baseSha: String?, remote: ManifestTree.Node?
    ) -> FormatChangeDecision {
        switch remote {
        case .file(_, let entry)?:
            // ベースが版の形でない（id の付け替え直後など）ときは、消す根拠が無いので競合側に倒す
            // （CLAUDE.md §7「ベース不明は拒否側」・PR #152 レビュー指摘 5: ツリーの sha で消すと、
            // この Mac が見ていない他の端末の版を S3 から外しうる）。
            guard let baseSha, baseSha == entry.sha256 else { return .conflict }
            return .replaceFile(oldSha: entry.sha256)
        case .package?:
            // 再試行（パッケージは書き済み）。ツリーではパッケージが勝つので、旧いファイルの entry が
            // 残っていてもツリーには見えない — ベースの sha で消しにいく（もう無ければ何もしない）。
            return .replaceFile(oldSha: baseSha)
        case nil:
            return .writeNew
        case .directory?:
            return .kindCollision
        }
    }

    /// 改名と同時に内容も変わった move（複合）で、旧 path の entry を消してよいか（PR #152 レビュー指摘 7）。
    /// システムが最後に見た版（`baseSha`）が旧 path の今の sha と一致するときだけ消す。合わない・ベースが
    /// 無い（版の形でない）ときは、他の端末の編集かもしれないので旧 path を残す（CLAUDE.md §7
    /// 「ベース不明は拒否側」）。内容の変わらない改名には当てない（中身はツリーの今の版をそのまま運ぶ）。
    public static func moveMayRemoveSource(baseSha: String?, current: String) -> Bool {
        baseSha == current
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
