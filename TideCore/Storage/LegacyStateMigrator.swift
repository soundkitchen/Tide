import Foundation

/// 旧ロケーション → App Group コンテナへの一度きり移行（M5 Phase 2〜3）。
///
/// 移行元は 2 世代あり、**新しい順**に試す（冪等ゲートにより最初に DB を持つ移行元が勝つ）:
/// 1. 旧 App Group コンテナ（`group.org.izukawa.Tide`・Phase 2 の一時ロケーション）。
///    `group.` 形式は macOS では TCC 保護され UI の無い拡張プロセスが拒否されるため、
///    Phase 3 でチーム ID プレフィックス形式（`G5G54TCH8W.org.izukawa.Tide`）へ移設した。
///    アプリ側 entitlement に旧 group を残してあるうちだけ読める。
/// 2. App Group 以前の実ホーム（`~/Library/Application Support/Tide` + 標準 UserDefaults）。
///    App Sandbox 下ではパスがコンテナ内に解決されて見えず自然に no-op。
///
/// 冪等: 移行先に DB / `setupCompleted` が既にあれば何もしない。旧ファイル・旧キーは
/// 消さない（データ損失 < 重複の原則）。旧残置分の完全削除は `make reset`（sandbox 外）
/// でのみ可能 — sandbox 下の `factoryReset` は実ホームの旧ロケーションに届かない。
///
/// **2 段コミット移行戦略の前提**: この移行は App Sandbox ON より**前の**ビルドを一度
/// 起動した時点で完了している想定。Sandbox ON 後は `.applicationSupportDirectory` が
/// コンテナ内に解決されて旧 DB は見えなくなる。**ただし旧 preferences plist は macOS が
/// サンドボックス初回起動時にコンテナへ自動移行（move）するため「旧設定だけは見える」**
/// （PR #49 レビュー #1・実機検証済み）。そこで設定移行は「legacy DB の実在」をゲートに
/// している（下記）。これにより中間ビルドを起動せず Sandbox 版へ飛んだ環境でも
/// 「設定あり・DB 空」の片肺移行にはならず、全体として no-op（＝新規状態でウィザード
/// 再設定）に落ちる。
public enum LegacyStateMigrator {
    public struct Outcome: Sendable {
        public var databaseMigrated = false
        public var configMigrated = false

        public init() {}
    }

    /// 移行元 1 つぶんの指定（ディレクトリ + defaults）。
    public struct LegacySource {
        public let supportTideDir: URL
        public let defaults: UserDefaults

        public init(supportTideDir: URL, defaults: UserDefaults) {
            self.supportTideDir = supportTideDir
            self.defaults = defaults
        }
    }

    /// production 用: 既知の移行元を新しい順に試す。冪等ゲート（移行先 DB / setupCompleted の有無）
    /// により、最初に実体を持っていた移行元が勝ち、以降は no-op になる。
    public static func migrateIfNeeded() -> Outcome {
        guard let groupSupport = try? TideAppGroup.supportDirectoryURL() else { return Outcome() }

        var sources: [LegacySource] = []
        // 1) 旧 App Group コンテナ（Phase 2 の group. 形式）
        if let legacyGroup = TideAppGroup.legacyContainerURL(),
           let legacyDefaults = UserDefaults(suiteName: TideAppGroup.legacyIdentifier) {
            sources.append(LegacySource(
                supportTideDir: legacyGroup.appendingPathComponent(
                    "Library/Application Support/Tide", isDirectory: true),
                defaults: legacyDefaults
            ))
        }
        // 2) App Group 以前の実ホーム（Sandbox 下では見えず自然に no-op）
        if let legacySupport = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        ) {
            sources.append(LegacySource(
                supportTideDir: legacySupport.appendingPathComponent("Tide", isDirectory: true),
                defaults: .standard
            ))
        }
        return migrateIfNeeded(
            legacySources: sources,
            groupSupportTideDir: groupSupport,
            groupDefaults: TideAppGroup.sharedDefaults()
        )
    }

    /// 複数移行元の連鎖（テスト注入可能）。先頭から順に試す＝先頭が新しい世代。
    public static func migrateIfNeeded(
        legacySources: [LegacySource],
        groupSupportTideDir: URL,
        groupDefaults: UserDefaults
    ) -> Outcome {
        var outcome = Outcome()
        for source in legacySources {
            let one = migrateIfNeeded(
                legacySupportTideDir: source.supportTideDir,
                legacyDefaults: source.defaults,
                groupSupportTideDir: groupSupportTideDir,
                groupDefaults: groupDefaults
            )
            outcome.databaseMigrated = outcome.databaseMigrated || one.databaseMigrated
            outcome.configMigrated = outcome.configMigrated || one.configMigrated
        }
        return outcome
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
        let legacyDBExists = fm.fileExists(atPath: legacyDB.path)
        var groupDBReady = fm.fileExists(atPath: groupDB.path)
        if !groupDBReady, legacyDBExists {
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
                groupDBReady = true
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
        //
        // 発火条件に「legacy DB が実在し、その内容が group 側に揃っている」を含める（PR #49 レビュー #1/#4）:
        // - macOS はサンドボックス初回起動時に旧 preferences plist をコンテナへ自動移行するため、
        //   「旧 defaults に setupCompleted が見える」だけでは非サンドボックス時代の実インストールが
        //   見えている証拠にならない（setupCompleted ⟹ DB 作成済み、なので DB の実在で判定できる）。
        //   DB を伴わない config-only 移行を許すと「設定あり・DB 空」で bootstrap がウィザードを
        //   スキップして起動し、全ファイル未追跡の全量再アップロード・競合コピー量産に至る。
        // - DB コピーが失敗した回に設定だけ移行すると、そのまま launchEngine が group パスに空 DB を
        //   生成して冪等キー（group 側 db.sqlite の有無）を汚し、次回の DB 移行リトライが永久に潰れる。
        //   設定移行ごとスキップすれば setupCompleted が立たず、次回起動が本当に頭からやり直せる。
        let setupKey = ConfigStore.setupCompletedDefaultsKey
        if legacyDBExists, groupDBReady,
           groupDefaults.object(forKey: setupKey) == nil,
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
