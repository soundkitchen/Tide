import AppKit
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
        // 未確定のレジストリ epoch bump をここで確定する（PR #106 レビュー指摘 2 の系）:
        // 「直前の Disable が timeout（結果不明）→ 後着で remove 完了」の並びだと、この add が
        // **新レプリカ**を作る。bump せずに add すると新レプリカの拡張が旧レジストリを有効
        // epoch として読む = #104 再発。レプリカが実は生存していた場合（remove 真失敗）は
        // 健全なレジストリを失うが、Disable → Enable はユーザ意図として作り直しサイクルであり
        // 喪失は有界（バッジ再報告で復元・仮想フォルダ温存/後始末予約の喪失のみ）。
        if TideAppGroup.sharedDefaults().bool(forKey: epochBumpPendingKey) {
            commitRegistryEpochBump()
        }
        // add の**前**に pending-add フラグを立てる（PR #101 六次レビュー指摘 6）: enable の throw
        // （XPC 一時失敗）を再起動横断で自己修復可能にする — setupCompleted 済みなら次回起動の
        // `migrateStaleDomainsIfNeeded` が add を再開し、未設定なら同ゲートがフラグを回収する。
        // 再作成分岐（disableForRecreation）だけでなくクリーンインストール分岐も対称になる。
        TideAppGroup.sharedDefaults().set(true, forKey: migrationPendingAddKey)
        // timeout throw 時もフラグが残る = 次回起動の migrate が再開する（有界化と自己修復の整合）
        try await boundedXPC("add(domain)") { try await NSFileProviderManager.add(domain) }
        // add 完了 = pending-add の意図は満たされた（確定点で消す）。
        TideAppGroup.sharedDefaults().removeObject(forKey: migrationPendingAddKey)
        AppLogger.ui.info("File Provider domain added")
    }

    /// ドメイン作り直しの前半（PR #101 再レビュー指摘 1）: **pending-add フラグを立ててから**
    /// 全ドメインを外し、「有効化済み」の意図を引き継ぐ（`migrateStaleDomainsIfNeeded` と同じ
    /// 順序 = remove 後の失敗/クラッシュでも意図が消えない）。呼び出し側（completeSetup の
    /// バケット切替）が remove 後の Keychain 保存 / `enable()` で throw しても、次回起動の
    /// `migrateStaleDomainsIfNeeded` が add を再開する = 再起動しても直らない無音の同期停止に
    /// ならない。**明示的な無効化**（factoryReset / Settings の Disable = 再有効化の意図なし）は
    /// 従来どおり `disable()`（フラグも消す）を使うこと。
    static func disableForRecreation() async throws {
        TideAppGroup.sharedDefaults().set(true, forKey: migrationPendingAddKey)
        try await removeAllDomainsInvalidatingRegistries()
        AppLogger.ui.info("File Provider domains removed for recreation (pending re-add)")
    }

    /// 旧世代を含む全ドメインを外す（factoryReset からも呼ぶ）。
    static func disable() async throws {
        // 明示的な無効化は移行再開の予約（pending-add）より優先する（残すと次回起動で勝手に
        // 再有効化される）。フラグ除去は removeAllDomains の**前**（PR #101 三次レビュー指摘 1）:
        // 後ろに置くと remove の throw（fileproviderd 無応答等）が呼び出し側の `try?`
        // （factoryReset）に握りつぶされたときフラグが生存し、全消し済みのアプリでも次回起動の
        // `migrateStaleDomainsIfNeeded`（setupCompleted ゲートより前に走る）が FP ドメインを
        // 無言で re-add → 未設定拡張のエラー列挙になる。先に消せば remove 失敗時はドメインが
        // 残るだけ（フラグ無しでも実害なし・Disable の再操作で回復できる）。
        TideAppGroup.sharedDefaults().removeObject(forKey: migrationPendingAddKey)
        try await removeAllDomainsInvalidatingRegistries()
        AppLogger.ui.info("File Provider domains removed")
    }

    /// レジストリ epoch bump が「予約済み・未確定」であることを示すフラグ（group defaults・
    /// Issue #104 / PR #106 レビュー指摘 1〜3）。remove 成功前のクラッシュ / timeout で残った
    /// 予約は、`enable()`（add 前に確定）と `migrateStaleDomainsIfNeeded` 冒頭（ドメイン実在の
    /// 観測で確定 or 取り下げ）が回収する。
    private static let epochBumpPendingKey = "fileProviderEpochBumpPending"

    /// 全ドメイン除去 + FP 拡張レジストリ（`PersistedPathSet` 3 本 = 実体化バッジ報告済み /
    /// 仮想フォルダ温存 / 除外後始末予約）の epoch 無効化のチョークポイント（Issue #104 /
    /// PR #106 レビュー指摘 3）。レジストリの内容はレプリカに紐づく保証で、レプリカ破棄を
    /// 跨いで生き残るとバッジ永久不点灯（報告済み = 差分なし）等で固着する。**レプリカを破棄
    /// する除去は必ずここを通すこと** — 素の `removeAllDomains()` 直呼びは #104 再発の扉。
    ///
    /// bump は **remove 成功後**に確定する（pending 予約 → remove → commit。レビュー指摘 1・2）:
    /// - **先 bump にしない**（指摘 2）: bump → remove の順だと、remove XPC 窓（最大 10 秒）で
    ///   fileproviderd が生成した新しい拡張インスタンスが**新 epoch を capture** し、死にゆく
    ///   レプリカの実体化セット等を新 epoch でスタンプし得る（= 作り直し後の新レプリカがそれを
    ///   有効値として読み #104 が再発）。remove 成功後なら旧レプリカの全書き手は旧 epoch
    ///   capture 済みで、遅延 persist ごと無効化される。
    /// - **remove 失敗（throw）では bump しない**（指摘 1）: timeout（fileproviderd 無応答）は
    ///   日常的な失敗モードで、レプリカは生きたまま使われ続ける可能性が高い。ここで bump すると
    ///   健全なレプリカから仮想フォルダの存在根拠（レジストリが唯一）を奪い、`item(for:)` の
    ///   noSuchItem → デーモンの掃除で**ユーザの空フォルダが実際に消える**。pending は残し、
    ///   後着でレプリカが実は消えていた場合の確定は `enable()` / 次回起動の観測が担う。
    /// - remove 成功 → commit 前のクラッシュは pending が生き残り、次回起動の
    ///   `migrateStaleDomainsIfNeeded` 冒頭が「現行ドメイン不在」の観測で bump を確定する。
    private static func removeAllDomainsInvalidatingRegistries() async throws {
        TideAppGroup.sharedDefaults().set(true, forKey: epochBumpPendingKey)
        try await boundedXPC("removeAllDomains()") { try await NSFileProviderManager.removeAllDomains() }
        commitRegistryEpochBump()
    }

    /// 予約済みの epoch bump を確定する（新 UUID へ前進 + pending クリア）。呼び出しは
    /// 「レプリカ破棄が確定した点」だけ: remove 成功直後 / add で新レプリカを作る直前
    /// （`enable()`・migrate の再作成分岐）/ 起動時の不在観測。
    private static func commitRegistryEpochBump() {
        ConfigStore().bumpFileProviderDomainEpoch()
        TideAppGroup.sharedDefaults().removeObject(forKey: epochBumpPendingKey)
        AppLogger.ui.notice("File Provider registry epoch bumped (replica destroyed)")
    }

    /// FP ドメインの詳細状態（Issue #103）。
    enum DomainStatus: Equatable, Sendable {
        /// 登録済み・拡張有効（同期が動ける唯一の状態）。
        case enabled
        /// 登録済みだがシステム設定（ログイン項目と機能拡張）で拡張がユーザ OFF = 全同期停止。
        case userDisabled
        /// 未登録（Disable 済み / 未セットアップ）。
        case notRegistered
    }

    /// FP ドメインの登録・有効状態。**nil = 取得失敗**（fileproviderd 無応答等・不明）。
    /// throw を潰すと「一時的な XPC 失敗」と「既知の未登録」が区別できず、呼び出し側 UI が
    /// 実在するドメインへの導線を誤って disable する（PR #100 再レビュー指摘 1）。
    /// 真偽が要る文脈は `== .enabled` / `!= .notRegistered` 等で明示的に倒す側を選ぶこと。
    ///
    /// `.userDisabled` の判定は `userEnabled` プロパティ（Issue #103・実機実証 2026-08-15）:
    /// システム設定のトグル OFF では **`domains()` に載ったまま** `userEnabled` だけが false に
    /// なる（反映 ≤15 秒）。掲載有無だけを見る旧 `isEnabled()` はこの状態を「有効」と誤判定し、
    /// 「緑表示のまま無音の同期停止」になっていた。
    static func domainStatus() async -> DomainStatus? {
        // 有界化（PR #101 十次レビュー指摘 1）: timeout も「取得失敗 = nil」に合流する。
        // probe 経由の全呼び出し（completeSetup / ウィザード / Settings / MenuBar / signaler）が
        // 一括で有界になる。
        try? await boundedXPC("domains()") {
            guard let current = try await NSFileProviderManager.domains()
                .first(where: { $0.identifier == domain.identifier })
            else { return DomainStatus.notRegistered }
            return current.userEnabled ? .enabled : .userDisabled
        }
    }

    /// セットアップ完了済みか（migrate の add ゲート用・PR #101 四次レビュー指摘 1 / 九次レビュー
    /// 指摘 5）。未設定アプリへの add は全分岐で禁止 — 拡張が fromSharedConfig nil の未設定エラー
    /// 列挙になるため。
    private static func isSetupCompleted() -> Bool {
        ConfigStore().setupCompleted
    }

    /// setupGate 保持区間から待つ fileproviderd XPC の有界化（PR #101 十次レビュー指摘 1）:
    /// fileproviderd はハング時にエラーも返さず戻らない（#96 受け入れ実測）ため、無界 await は
    /// ゲートを永久保持して全ライフサイクル操作（bootstrap / completeSetup / factoryReset /
    /// Enable・Disable）を再起動まで固着させる。TaskGroup は使えない — スコープ終了時に全 child を
    /// 待つため、キャンセル非対応の XPC が parked だと timeout 側が勝ってもグループごと固着する。
    /// 一度きり resume の continuation レース（両 Task とも MainActor 直列 = claim は原子的）で
    /// 有界化する。**timeout しても下層 XPC は中断されない**（後着で完了し得る）ので、後着完了が
    /// 無害（冪等 add / remove・読み取り）な操作だけを通すこと。
    private static func boundedXPC<T>(
        _ label: String, seconds: Double = 10,
        _ op: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let once = OnceGate()
            Task { @MainActor in
                do {
                    let value = try await op()
                    if once.claim() { continuation.resume(returning: value) }
                } catch {
                    if once.claim() { continuation.resume(throwing: error) }
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                if once.claim() {
                    AppLogger.ui.error("File Provider XPC timed out after \(seconds)s: \(label, privacy: .public)")
                    continuation.resume(throwing: SyncError.ioError(underlying: NSError(
                        domain: "Tide.FileProviderController", code: -10,
                        userInfo: [NSLocalizedDescriptionKey: "\(label) timed out — fileproviderd is not responding"]
                    )))
                }
            }
        }
    }

    /// `boundedXPC` の一度きり resume ガード（両レース Task が MainActor 直列のため claim は原子的）。
    @MainActor
    private final class OnceGate {
        private var claimed = false
        func claim() -> Bool {
            if claimed { return false }
            claimed = true
            return true
        }
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
        // 有界化（十次レビュー指摘 1）: この migrate は drainDomainMigration 経由で setupGate
        // 保持側（completeSetup 等）から await されるため、内部 XPC が無界だとゲート固着に波及する。
        // timeout = 取得失敗（空扱い）→ no-op で戻る（フラグ類は温存 = 次回起動で再試行）。
        let fetchedDomains = try? await boundedXPC("domains()") { try await NSFileProviderManager.domains() }
        // 予約済み epoch bump の起動時確定（Issue #104 / PR #106 レビュー指摘 1・2）:
        // 「remove 成功 → commit 前」のクラッシュ / timeout 中断をここで回収する。現行ドメイン
        // **不在** = 前回の除去は実際に完了していた → bump 確定（この後の add 分岐が新レプリカを
        // 作る前に旧レジストリを無効化）。**実在** = 前回の remove は本当に失敗しレプリカ生存 →
        // 予約を取り下げる（生きたレジストリ = 仮想フォルダの存在根拠を奪わない。観測後に後着
        // remove が完了する極小窓は容認 — その場合も Disable → Enable の再操作で回復できる）。
        // 取得失敗（nil）は判定不能 → 予約温存（次回起動 / enable() で再判定）。
        if let fetchedDomains, defaults.bool(forKey: epochBumpPendingKey) {
            if fetchedDomains.contains(where: { $0.identifier == domain.identifier }) {
                defaults.removeObject(forKey: epochBumpPendingKey)
                AppLogger.ui.notice("File Provider registry epoch bump withdrawn (current replica survived)")
            } else {
                commitRegistryEpochBump()
            }
        }
        let domains = fetchedDomains ?? []
        let staleDomains = domains.filter { $0.identifier != domain.identifier }
        let hasCurrent = domains.contains { $0.identifier == domain.identifier }

        if staleDomains.isEmpty {
            // 前回の移行が「stale 除去後・add 前」で中断していたら add だけ再開する。
            guard defaults.bool(forKey: migrationPendingAddKey) else { return }
            // 未設定アプリでは add しない（PR #101 四次レビュー指摘 1）: factoryReset 後の
            // 再セットアップが disableForRecreation 直後（Keychain 保存等）で中断すると、
            // setupCompleted 未確定のままフラグだけが残る。この migrate は setupCompleted
            // ゲートより前（bootstrap 冒頭）に走るため、ゲート無しだと全消し済みアプリへ
            // ドメインを無言 re-add → 拡張が fromSharedConfig nil で未設定エラー列挙になる。
            // フラグは回収してよい — 正規のセットアップ完了時は enable() が無条件に add する
            // ためフラグ無しで困らない。
            guard isSetupCompleted() else {
                defaults.removeObject(forKey: migrationPendingAddKey)
                AppLogger.ui.notice("Skipping pending File Provider domain re-add (setup not completed); cleared pending flag")
                return
            }
            if !hasCurrent {
                do {
                    try await boundedXPC("add(domain)") { try await NSFileProviderManager.add(domain) }
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

        // 未設定アプリでは現行ドメインの add を行わない（四次レビュー指摘 1 の setupCompleted
        // ゲートを九次レビュー指摘 5 で stale 分岐へも拡大 — factoryReset の disable 失敗握りつぶし
        // 〈try?〉後は「stale 生存 × 全消し済み」の組合せがあり得る）。stale の**除去だけ**行い、
        // add はセットアップ完了後の enable() に委ねる（add しないためフラグも立てない）。
        let setupCompleted = isSetupCompleted()
        // remove の前にフラグを立てる（remove 成功 → add 失敗/クラッシュでも意図が消えない順序）。
        if setupCompleted {
            defaults.set(true, forKey: migrationPendingAddKey)
        }
        // レジストリ epoch（Issue #104）: 現行 identifier のドメインが**無い**ときだけ予約 →
        // stale 除去成功後に確定する — この分岐の add（またはフラグ経由の後続 add）が現行
        // レプリカをゼロから作るため、既存レジストリはすべて死んだレプリカ由来の stale。
        // 確定は add より**前**（後だと新レプリカの拡張が旧 epoch を capture して stale を有効値
        // として読む）・stale remove の成功より**後**（チョークポイントと同じ pending → commit
        // 順序 = 途中失敗では bump しない）。hasCurrent なら現行レプリカは温存される
        // （per-domain remove は stale "poc" だけ外す・PR #61 レビュー #2）ため予約自体しない —
        // bump すると生きているレプリカの報告済み/温存/予約を無駄に破棄する。
        if !hasCurrent {
            defaults.set(true, forKey: epochBumpPendingKey)
        }
        do {
            for stale in staleDomains {
                try await boundedXPC("remove(stale)") { try await NSFileProviderManager.remove(stale) }
            }
            if !hasCurrent {
                commitRegistryEpochBump()
            }
            if !hasCurrent && setupCompleted {
                try await boundedXPC("add(domain)") { try await NSFileProviderManager.add(domain) }
            }
            defaults.removeObject(forKey: migrationPendingAddKey)
            AppLogger.ui.info("Migrated stale File Provider domain(s) to current identifier")
        } catch {
            // remove 失敗なら stale が残り次回の migrate が再走する。add 失敗なら pending フラグが
            // add の再開を保証する。いずれも設定画面の Disable → Enable で即時回復もできる。
            AppLogger.ui.error("File Provider domain migration failed: \(String(describing: error), privacy: .private)")
        }
    }

    /// FP ドメインのルート（`~/Library/CloudStorage/Tide-Tide`）の Finder 表示 URL を返す
    /// （未登録 / 取得失敗は nil）。fpOnly ポップオーバーの「Open Tide in Finder」用（B-1）。
    static func userVisibleURL() async -> URL? {
        // 意図的に**有界化しない**（十次レビュー指摘 1 の対象外）: setupGate 保持区間から呼ばれず
        // （メニュー / done 画面のユーザ操作のみ）、#96 受け入れ実測どおりハング時は後着完了で
        // 正しい Finder が遅れて開く（誤動作なし）。timeout で縮退させる方が体験が悪化する。
        guard let manager = NSFileProviderManager(for: domain) else { return nil }
        return try? await manager.getUserVisibleURL(for: .rootContainer)
    }

    /// 「Tide を Finder で開く」導線用: `userVisibleURL()` が取れないとき（fileproviderd 無応答等）は
    /// 実ホームの `~/Library/CloudStorage`（全プロバイダ共通の親）へ縮退する — 唯一の Finder 導線を
    /// 無音 no-op にしないための best-effort（PR #100 レビュー指摘 4・再レビュー指摘 4 で移設）。
    /// レプリカ実体 `…/CloudStorage/Tide-Tide` を直接使わないのは意図的な保守側の選択 —
    /// ディレクトリ名は OS が displayName から合成するもので、パス恒常性の公開契約が無い。
    /// `isFallback` は scope 開始の要否判定用（本物の URL は security-scoped・縮退 URL は素のパス）。
    /// private（PR #101 七次レビュー指摘 6）: 呼び出しは scope 開始込みの
    /// `openUserVisibleFolderInFinder()` に一本化されており、外部へ開けておくと
    /// 「scope 開始漏れ」（B-2 受け入れバグ）を将来の呼び出し側が再導入する扉になる。
    private static func userVisibleURLOrFallback() async -> (url: URL, isFallback: Bool) {
        if let url = await userVisibleURL() { return (url, false) }
        let fallback = URL(
            fileURLWithPath: PathValidator.realHomeDirectory(), isDirectory: true
        ).appendingPathComponent("Library/CloudStorage", isDirectory: true)
        return (fallback, true)
    }

    /// FP レプリカ（Finder の「場所 → Tide」）を Finder で開く。URL 取得は XPC 越しなので非同期。
    /// URL が取れない（fileproviderd 無応答等）ときは `userVisibleURLOrFallback` の縮退 URL
    /// （実ホームの `~/Library/CloudStorage`）を best-effort で開く（唯一の Finder 導線を無音
    /// no-op にしない・PR #100 レビュー指摘 4。sandbox 下の LS がこのパスを拒否する可能性は
    /// 残るため、成否はログで観測する）。ポップオーバーとセットアップ完了画面が共用する
    /// （#97。security scope の開始漏れ = B-2 受け入れで踏んだバグの構造的再発防止）。
    static func openUserVisibleFolderInFinder() async {
        let (url, isFallback) = await userVisibleURLOrFallback()
        if isFallback {
            let opened = NSWorkspace.shared.open(url)
            AppLogger.ui.info("Open Tide in Finder: userVisibleURL unavailable; CloudStorage fallback opened=\(opened)")
            return
        }
        // getUserVisibleURL の返す URL は security-scoped。scope を開始せずに NSWorkspace へ
        // 渡すと、sandbox 下では LS が「"Tide-Tide" を開くアクセス権がありません」で拒否する
        // （B-2 実機受け入れで発見・Apple Developer Forums thread 724398 と同事例）。
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        NSWorkspace.shared.open(url)
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
            // 取得失敗（nil）・userDisabled も signal しない側に倒す（従来挙動の維持 — signal は
            // fire-and-forget の補助経路で、拡張側の世代キャッシュ・定期契機が取りこぼしを回収する。
            // userDisabled は拡張が起動できないため signal しても届かない・#103）。
            guard await domainStatus() == .enabled, let manager = NSFileProviderManager(for: domain) else { return }
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
