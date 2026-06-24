import Foundation

/// 「このパスを同期からスキップするか」を決める二段判定（純粋関数）。
///
/// 判定順（`docs/07-M3-IMPLEMENTATION-GUIDE.md` サブタスク B / `docs/08-IMPLEMENTATION-NOTES.md`）:
/// 1. `HardcodedIgnoreRules` にマッチ → 追跡状態に関係なく常にスキップ（機密網は最優先・否定でも覆せない）
/// 2. `.syncignore` ファイル自身（ルート/ネスト両方）→ 決してスキップしない（除外設定が同期から外れて消えるのを防ぐ）
/// 3. `.syncignore` のユーザパターン（階層合成 = `LayeredSyncIgnore`）にマッチ かつ 未追跡 → スキップ
///    （新規のみ。既存追跡は触らない＝gitignore 純正）
/// 4. それ以外 → スキップしない
enum IgnoreDecision {
    /// 同期ルートからの相対パス（POSIX）が同期対象から外れるか。
    /// - Parameter isAlreadyTracked: 対応する `FileRecord` が存在し `lastSyncedAt != nil` であること。
    static func shouldSkip(
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

    /// ルート直下またはネストした `.syncignore` 自身か。決して除外せず、変更検知の契機にも使う共有判定。
    /// （ネスト対応で `path == ".syncignore"` の完全一致では取りこぼすため `hasSuffix("/.syncignore")` も見る。）
    static func isSyncignoreFile(_ relativePath: String) -> Bool {
        relativePath == ".syncignore" || relativePath.hasSuffix("/.syncignore")
    }
}
