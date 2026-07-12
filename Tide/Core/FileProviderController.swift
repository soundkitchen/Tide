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
        AppLogger.ui.info("File Provider domains removed")
    }

    static func isEnabled() async -> Bool {
        let domains = (try? await NSFileProviderManager.domains()) ?? []
        return domains.contains { $0.identifier == domain.identifier }
    }

    /// 旧 identifier（PoC 世代の "poc"）のドメインが残っていたら現行 identifier で作り直す。
    /// identifier スキーマの変更は必ずドメイン作り直しで行う — 既存レプリカへの無再作成移行では
    /// 旧 id item が「名前 2」リネームで恒久残存する（docs/09 M5 節・Phase 5-1 実機確定）。
    /// 「有効化済み」というユーザ意図は新ドメインの再登録で引き継ぐ。ドメイン無し/現行のみなら no-op。
    static func migrateStaleDomainsIfNeeded() async {
        let domains = (try? await NSFileProviderManager.domains()) ?? []
        guard domains.contains(where: { $0.identifier != domain.identifier }) else { return }
        do {
            try await NSFileProviderManager.removeAllDomains()
            try await NSFileProviderManager.add(domain)
            AppLogger.ui.info("Migrated stale File Provider domain(s) to current identifier")
        } catch {
            // 失敗しても致命ではない（旧ドメインが残るだけ）。設定画面の Disable → Enable で回復できる。
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
