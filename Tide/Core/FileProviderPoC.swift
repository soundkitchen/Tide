import FileProvider
import Foundation
import TideCore

/// File Provider ドメインの登録/解除（M5 Phase 3・読み取り materialize PoC のデバッグ導線）。
/// ドメインを登録すると OS が `~/Library/CloudStorage` 配下に Tide のボリュームを生やし、
/// `TideFileProvider.appex` がマニフェスト由来のプレースホルダを列挙する。
/// 既存の FSEvents 同期（同期フォルダ）とは独立で、登録してもしなくても同期挙動は変わらない。
@MainActor
enum FileProviderPoC {
    /// PoC ドメイン。identifier は安定文字列（変えると別ドメイン＝別フォルダになる）。
    static let domain: NSFileProviderDomain = {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: "poc"),
            displayName: "Tide"
        )
        // PoC はゴミ箱同期を扱わない。宣言しないとデーモンが .trashContainer の列挙を
        // 要求し続け、itemNotFound を永久リトライする（実機 fileproviderctl dump で確認）。
        domain.supportsSyncingTrash = false
        return domain
    }()

    static func enable() async throws {
        try await NSFileProviderManager.add(domain)
        AppLogger.ui.info("File Provider PoC domain added")
    }

    /// PoC ドメインを含む全ドメインを外す（factoryReset からも呼ぶ）。
    static func disable() async throws {
        try await NSFileProviderManager.removeAllDomains()
        AppLogger.ui.info("File Provider domains removed")
    }

    static func isEnabled() async -> Bool {
        let domains = (try? await NSFileProviderManager.domains()) ?? []
        return domains.contains { $0.identifier == domain.identifier }
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
