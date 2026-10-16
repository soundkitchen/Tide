import Foundation

/// 「このパスを同期からスキップするか」を決める二段判定（純粋関数）。
///
/// 判定順（`docs/07-M3-IMPLEMENTATION-GUIDE.md` サブタスク B / `docs/08-IMPLEMENTATION-NOTES.md`）:
/// 1. `HardcodedIgnoreRules` にマッチ → 追跡状態に関係なく常にスキップ（機密網は最優先・否定でも覆せない）
/// 2. `.syncignore` ファイル自身（ルート/ネスト両方）→ 決してスキップしない（除外設定が同期から外れて消えるのを防ぐ）
/// 3. `.syncignore` のユーザパターン（階層合成 = `LayeredSyncIgnore`）にマッチ かつ 未追跡 → スキップ
///    （新規のみ。既存追跡は触らない＝gitignore 純正）
/// 4. それ以外 → スキップしない
public enum IgnoreDecision {
    /// 同期ルートからの相対パス（POSIX）が同期対象から外れるか。
    /// - Parameter isAlreadyTracked: 対応する `FileRecord` が存在し `lastSyncedAt != nil` であること。
    public static func shouldSkip(
        relativePath: String,
        isAlreadyTracked: Bool,
        matcher: LayeredSyncIgnore
    ) -> Bool {
        if HardcodedIgnoreRules.shouldIgnore(relativePath: relativePath) {
            return true
        }
        if isSyncignoreFile(relativePath) {
            return false
        }
        if matcher.isIgnored(relativePath) {
            return !isAlreadyTracked
        }
        return false
    }

    /// ディレクトリを subtree ごと（フォルダ単位で）同期対象外にするか（FP 拡張・#120）。
    ///
    /// fileproviderd は除外（`excludedFromSync`）したアイテムを 1 件ずつ記録し、拡張の更新のたびに
    /// 全件へ createItem を再送する。配下を 1 ファイルずつ除外すると件数がそのまま再送量になる
    /// ため、フォルダごと除外できる場合はフォルダ 1 件で済ませる。判定順:
    /// 1. 配下に追跡済みファイルがある → しない（フォルダ除外の後始末 deleteItem が S3 から
    ///    追跡済みファイルを消すため。機密網より先に見る = 既存の追跡を巻き込まない）
    /// 2. 機密網（`HardcodedIgnoreRules`）にマッチ → する
    /// 3. 効いている `.syncignore` 層に否定（`!`）がある → しない（配下の再包含を 1 ファイルずつの
    ///    判定で再現するため）
    /// 4. ユーザパターンが `<dir>/` を除外 → する（`*.pyc` のようなファイル向けパターンは
    ///    ディレクトリに一致しないので対象外 = 従来どおり 1 ファイルずつ）
    ///
    /// FP 拡張の createItem（新規フォルダ）は、この関数より前に機密網だけを即決している（ツリーを
    /// 引かずオフラインでも拒否するため・5-3 からの既存挙動）。新規フォルダの path にツリー上の
    /// 追跡済みファイルがあるのは同名の衝突時に限られ、その解消はシステムの名前衝突処理に任せる。
    /// 1 と 2 の順序が効くのは modifyItem（受理済みフォルダの除外）の経路。
    ///
    /// フォルダごと除外すると、その中に置かれた `.syncignore` も同期しない（git が除外ディレクトリ
    /// 内の `.gitignore` を読まないのと同じ・2026-10-16 ユーザ確定）。
    /// - Parameter hasTrackedDescendants: マニフェストのツリーにこのパスのノードがあるか
    ///   （ツリーのディレクトリは配下の追跡ファイルから合成されるため、あれば配下に追跡済みがある）。
    public static func shouldExcludeDirectory(
        relativePath: String,
        hasTrackedDescendants: Bool,
        matcher: LayeredSyncIgnore
    ) -> Bool {
        if hasTrackedDescendants {
            return false
        }
        return excludesDirectoryAsWhole(relativePath: relativePath, matcher: matcher)
    }

    /// 改名・移動の先のフォルダを subtree ごと同期対象外にするか（FP 拡張の rename 経路・#124）。
    ///
    /// `shouldExcludeDirectory` の判定 2〜4 だけを使う。判定 1（配下に追跡済みあり → しない）は
    /// 見ない — 追跡済みファイルを含むフォルダを除外名へ改名して、旧パスの後始末で S3 から外すのが
    /// 改名経路の意図した挙動のため（FSEvents モードの「旧 path 削除伝播 + 新 path 非同期」と対称）。
    ///
    /// 効いている層に否定（`!`）があれば除外しない = 改名を受理する（2026-10-17 ユーザ確定）。
    /// 配下の追跡済みファイルは新しいパスへ移って追跡が続き（ユーザパターンは未追跡にだけ効く）、
    /// 改名後に新しく作るファイルは 1 ファイルずつ判定される。新規作成の経路と同じく、`!` で再包含
    /// したファイルが改名を機に S3 から外れることはない。
    ///
    /// 改名するフォルダ自身の `.syncignore` はツリー上では旧パスにあるので、ここでは見ない
    ///（フォルダごと除外したフォルダの中の `.syncignore` を読まないのと同じ扱い）。
    public static func shouldExcludeDirectoryOnRename(
        relativePath: String,
        matcher: LayeredSyncIgnore
    ) -> Bool {
        excludesDirectoryAsWhole(relativePath: relativePath, matcher: matcher)
    }

    /// フォルダ単位除外の判定 2〜4（機密網 → 否定あり → `<dir>/` の照合）。
    private static func excludesDirectoryAsWhole(
        relativePath: String,
        matcher: LayeredSyncIgnore
    ) -> Bool {
        if HardcodedIgnoreRules.shouldIgnore(relativePath: relativePath) {
            return true
        }
        if matcher.hasNegatedPattern(applyingTo: relativePath) {
            return false
        }
        return matcher.evaluate(relativePath + "/") == .ignored
    }

    /// ルート直下またはネストした `.syncignore` 自身か。決して除外せず、変更検知の契機にも使う共有判定。
    /// （ネスト対応で `path == ".syncignore"` の完全一致では取りこぼすため `hasSuffix("/.syncignore")` も見る。）
    public static func isSyncignoreFile(_ relativePath: String) -> Bool {
        relativePath == ".syncignore" || relativePath.hasSuffix("/.syncignore")
    }
}
