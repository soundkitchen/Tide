import Foundation

/// 「このパスを同期からスキップするか」を決める二段判定（純粋関数）。
///
/// 判定順（`docs/07-M3-IMPLEMENTATION-GUIDE.md` サブタスク B / `docs/08-IMPLEMENTATION-NOTES.md`）:
/// 1. `HardcodedIgnoreRules` にマッチ → 追跡状態に関係なく常にスキップ（機密網は最優先・否定でも覆せない）
/// 2. `.syncignore` ファイル自身 → 決してスキップしない（除外設定が同期から外れて消えるのを防ぐ）
/// 3. `.syncignore` のユーザパターンにマッチ かつ 未追跡 → スキップ（新規のみ。既存追跡は触らない＝gitignore 純正）
/// 4. それ以外 → スキップしない
enum IgnoreDecision {
    /// 同期ルートからの相対パス（POSIX）が同期対象から外れるか。
    /// - Parameter isAlreadyTracked: 対応する `FileRecord` が存在し `lastSyncedAt != nil` であること。
    static func shouldSkip(
        relativePath: String,
        isAlreadyTracked: Bool,
        matcher: SyncIgnoreMatcher
    ) -> Bool {
        if HardcodedIgnoreRules.shouldIgnore(relativePath: relativePath) {
            return true
        }
        if relativePath == ".syncignore" {
            return false
        }
        if matcher.isIgnored(relativePath) {
            return !isAlreadyTracked
        }
        return false
    }
}
