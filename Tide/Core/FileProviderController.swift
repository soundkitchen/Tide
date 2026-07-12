import FileProvider
import Foundation
import TideCore

/// File Provider ドメインの登録/解除と signal 配線（M5・設定画面の Enable/Disable が正規導線）。
/// ドメインを登録すると OS が `~/Library/CloudStorage` 配下に Tide のボリュームを生やし、
/// `TideFileProvider.appex` がマニフェスト由来のプレースホルダを列挙・双方向同期する
/// （拡張は S3 へ直接書く「第 3 のデバイス」方式。M5 Phase 5〜）。
/// 既存の FSEvents 同期（同期フォルダ）とは並走し、どちらも同じバケットへ同期する。
@MainActor
enum FileProviderController {
    /// FP ドメイン。identifier は安定文字列（変えると別ドメイン＝別フォルダになる）。
    /// 変更時は `migrateStaleDomainsIfNeeded` が旧 identifier ドメインを作り直す。
    static let domain: NSFileProviderDomain = {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: "main"),
            displayName: "Tide"
        )
        // ゴミ箱同期は扱わない。宣言しないとデーモンが .trashContainer の列挙を
        // 要求し続け、itemNotFound を永久リトライする（実機 fileproviderctl dump で確認）。
        domain.supportsSyncingTrash = false
        return domain
    }()

    static func enable() async throws {
        try await NSFileProviderManager.add(domain)
        AppLogger.ui.info("File Provider domain added")
    }

    /// 旧世代を含む全ドメインを外す（factoryReset からも呼ぶ）。
    static func disable() async throws {
        try await NSFileProviderManager.removeAllDomains()
        // 明示的な無効化は移行再開の予約より優先する（残すと次回起動で勝手に再有効化される）。
        TideAppGroup.sharedDefaults().removeObject(forKey: migrationPendingAddKey)
        AppLogger.ui.info("File Provider domains removed")
    }

    static func isEnabled() async -> Bool {
        let domains = (try? await NSFileProviderManager.domains()) ?? []
        return domains.contains { $0.identifier == domain.identifier }
    }

    /// 移行が「stale 除去済み・現行 add 未完了」で中断したことを示すフラグ（group defaults）。
    /// 立っている間は次回の migrate が add を再試行する＝「有効化済み」意図が失われない
    /// （PR #61 レビュー #1: remove 成功 → add 失敗だと stale 検出が no-op になり移行が再走しない）。
    private static let migrationPendingAddKey = "fileProviderMigrationPendingAdd"

    /// 旧 identifier（PoC 世代の "poc"）のドメインが残っていたら現行 identifier で作り直す。
    /// identifier スキーマの変更は必ずドメイン作り直しで行う — 既存レプリカへの無再作成移行では
    /// 旧 id item が「名前 2」リネームで恒久残存する（docs/09 M5 節・Phase 5-1 実機確定）。
    /// 作り直しは旧ドメインのレプリカごと破棄する＝旧ドメイン内の S3 未到達の保留書込は失われる
    /// （identifier 変更時に作り直しを了承済み・一度きり）。
    /// stale は per-domain `remove(_:)` で外す — 現行 "main" が共存していてもそのレプリカ・
    /// 保留書込は温存する（PR #61 レビュー #2。`removeAllDomains` は使わない）。
    /// 「有効化済み」というユーザ意図は remove 前に立てる pending フラグ + 再登録で引き継ぐ。
    /// ドメイン無し/現行のみ（かつ pending なし）なら no-op。
    static func migrateStaleDomainsIfNeeded() async {
        let defaults = TideAppGroup.sharedDefaults()
        let domains = (try? await NSFileProviderManager.domains()) ?? []
        let staleDomains = domains.filter { $0.identifier != domain.identifier }
        let hasCurrent = domains.contains { $0.identifier == domain.identifier }

        if staleDomains.isEmpty {
            // 前回の移行が「stale 除去後・add 前」で中断していたら add だけ再開する。
            guard defaults.bool(forKey: migrationPendingAddKey) else { return }
            if !hasCurrent {
                do {
                    try await NSFileProviderManager.add(domain)
                    AppLogger.ui.info("Resumed File Provider domain migration (add completed)")
                } catch {
                    // フラグ残置＝次回起動で再試行。設定画面の Enable でも回復できる。
                    AppLogger.ui.error("File Provider domain migration resume failed: \(String(describing: error), privacy: .private)")
                    return
                }
            }
            defaults.removeObject(forKey: migrationPendingAddKey)
            return
        }

        // remove の前にフラグを立てる（remove 成功 → add 失敗/クラッシュでも意図が消えない順序）。
        defaults.set(true, forKey: migrationPendingAddKey)
        do {
            for stale in staleDomains {
                try await NSFileProviderManager.remove(stale)
            }
            if !hasCurrent {
                try await NSFileProviderManager.add(domain)
            }
            defaults.removeObject(forKey: migrationPendingAddKey)
            AppLogger.ui.info("Migrated stale File Provider domain(s) to current identifier")
        } catch {
            // remove 失敗なら stale が残り次回の migrate が再走する。add 失敗なら pending フラグが
            // add の再開を保証する。いずれも設定画面の Disable → Enable で即時回復もできる。
            AppLogger.ui.error("File Provider domain migration failed: \(String(describing: error), privacy: .private)")
        }
    }

    /// リモート変化（pull がシャード変化を取り込んだ / アップロードがマニフェストを書いた）を
    /// FP ドメインへ通知する（M5 Phase 4・アプリ側が主経路）。fire-and-forget・未登録なら no-op。
    /// replicated 拡張への signal は `.workingSet` のみ有効（他コンテナは無視される）。
    /// 拡張側は enumerateChanges 応答で TTL を待たず増分ロードするため、この signal が
    /// 実質のリモート追従トリガになる。
    static func signalRemoteChanges() {
        // コアレス（PR #56 レビュー ③）: 確定点発火（M5 Phase 5-0）はアップロード 1 件ごとに
        // 呼ばれるため、大量アップロード時に signal（XPC 2 回/呼）が件数分に増幅する。
        // 「即時 1 発 + クールダウン中の後着はトレーリング 1 発」に集約する — 先頭は遅延ゼロで
        // 従来の反映速度を保ち、トレーリング再発火が「窓中の最後の書込」の取りこぼしを防ぐ。
        if signalCooldownTask != nil {
            signalPendingDuringCooldown = true
            return
        }
        performSignal()
        signalCooldownTask = Task {
            try? await Task.sleep(for: .seconds(1))
            signalCooldownTask = nil
            if signalPendingDuringCooldown {
                signalPendingDuringCooldown = false
                signalRemoteChanges()
            }
        }
    }

    private static var signalCooldownTask: Task<Void, Never>?
    private static var signalPendingDuringCooldown = false

    private static func performSignal() {
        Task {
            guard await isEnabled(), let manager = NSFileProviderManager(for: domain) else { return }
            do {
                try await manager.signalEnumerator(for: .workingSet)
                AppLogger.sync.debug("Signaled File Provider working set")
            } catch {
                // 一過性（拡張未起動等）は次の pull / ブラウズ時の自己 signal で追いつく
                AppLogger.sync.error("File Provider signal failed: \(String(describing: error), privacy: .private)")
            }
        }
    }
}
