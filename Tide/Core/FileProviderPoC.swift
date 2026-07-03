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
