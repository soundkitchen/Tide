import Foundation

/// 旧ロケーション（非 App Group）→ App Group コンテナへの一度きり移行（M5 Phase 2）。
///
/// 対象:
/// - ローカル DB: `~/Library/Application Support/Tide/db.sqlite`（+ `-wal` / `-shm`）
///   → group container 内 `Library/Application Support/Tide/`
/// - 設定: 標準 UserDefaults（`org.izukawa.Tide`）の `tide.*` キー
///   → group suite（`group.org.izukawa.Tide`）
///
/// 冪等: 移行先に DB / `setupCompleted` が既にあれば何もしない。旧ファイル・旧キーは
/// 消さない（データ損失 < 重複の原則。`make reset` / `factoryReset` が新旧両方を消す）。
///
/// **2 段コミット移行戦略の前提**: この移行は App Sandbox ON より**前の**ビルドを一度
/// 起動した時点で完了している想定。Sandbox ON 後は `.applicationSupportDirectory` も
/// standard defaults もコンテナ内に解決されて旧データが見えなくなるため、未移行のまま
/// Sandbox 版へ飛んだ環境では自然に no-op（＝新規状態でウィザード再設定）に落ちる。
public enum LegacyStateMigrator {
    public struct Outcome: Sendable {
        public var databaseMigrated = false
        public var configMigrated = false

        public init() {}
    }

    /// production 用: 実行プロセスから見た旧パス・標準 defaults を使って移行する。
    /// 旧パス解決に失敗した場合（実質起きない）は何もしない。
    public static func migrateIfNeeded() -> Outcome {
        guard
            let legacySupport = try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: false
            ),
            let groupSupport = try? TideAppGroup.supportDirectoryURL()
        else {
            return Outcome()
        }
        return migrateIfNeeded(
            legacySupportTideDir: legacySupport.appendingPathComponent("Tide", isDirectory: true),
            legacyDefaults: .standard,
            groupSupportTideDir: groupSupport,
            groupDefaults: TideAppGroup.sharedDefaults()
        )
    }

    /// テスト可能な注入版。
    public static func migrateIfNeeded(
        legacySupportTideDir: URL,
        legacyDefaults: UserDefaults,
        groupSupportTideDir: URL,
        groupDefaults: UserDefaults
    ) -> Outcome {
        var outcome = Outcome()
        let fm = FileManager.default

        // ── DB ファイル一式（冪等キーは本体 db.sqlite の有無）
        let legacyDB = legacySupportTideDir.appendingPathComponent("db.sqlite")
        let groupDB = groupSupportTideDir.appendingPathComponent("db.sqlite")
        if !fm.fileExists(atPath: groupDB.path), fm.fileExists(atPath: legacyDB.path) {
            do {
                try fm.createDirectory(at: groupSupportTideDir, withIntermediateDirectories: true)
                // WAL/SHM を先・本体を最後にコピーする: 冪等判定が本体の有無なので、
                // 途中クラッシュしても次回起動で頭から安全に再試行できる
                // （本体だけ在って WAL が無い＝直近トランザクション欠落、を作らない）。
                for suffix in ["-wal", "-shm", ""] {
                    let src = legacySupportTideDir.appendingPathComponent("db.sqlite" + suffix)
                    let dst = groupSupportTideDir.appendingPathComponent("db.sqlite" + suffix)
                    guard fm.fileExists(atPath: src.path) else { continue }
                    if fm.fileExists(atPath: dst.path) {
                        try fm.removeItem(at: dst)
                    }
                    try fm.copyItem(at: src, to: dst)
                }
                outcome.databaseMigrated = true
                AppLogger.db.info("Migrated legacy database into App Group container")
            } catch {
                AppLogger.db.error("Legacy DB migration failed: \(String(describing: error), privacy: .private)")
                // 中途半端なコピーを残さない（本体が残ると冪等判定が「移行済み」に化ける）
                for suffix in ["", "-wal", "-shm"] {
                    try? fm.removeItem(
                        at: groupSupportTideDir.appendingPathComponent("db.sqlite" + suffix)
                    )
                }
            }
        }

        // ── 設定（冪等キーは group 側 setupCompleted の有無。旧側でセットアップ完了済みの時だけ移す）
        let setupKey = ConfigStore.setupCompletedDefaultsKey
        if groupDefaults.object(forKey: setupKey) == nil,
           legacyDefaults.object(forKey: setupKey) != nil {
            for key in ConfigStore.migratableKeys {
                if let value = legacyDefaults.object(forKey: key) {
                    groupDefaults.set(value, forKey: key)
                }
            }
            outcome.configMigrated = true
            AppLogger.db.info("Migrated legacy config into App Group defaults suite")
        }

        return outcome
    }
}
