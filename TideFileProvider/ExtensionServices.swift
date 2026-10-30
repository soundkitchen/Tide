import CryptoKit
import FileProvider
import Foundation
import os
import TideCore

/// FileProvider の observer / completion handler のような「どのスレッドから呼んでも良い契約だが
/// Sendable 注釈が無い」値を Task へ運ぶための箱。
struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
}

/// 拡張プロセスの依存一式。App Group 共有の設定（group defaults）と Keychain（共有 access group）
/// から構築する。**DB には触らない**（Phase 3 からの不変条件。世代ログは App Group Caches の
/// 拡張専用 JSON = GRDB 非接触）。
struct ExtensionServices: Sendable {
    /// 実体化バッジ（Issue #65）: 報告済みレジストリの上限。実体化ファイル数は既定の 1000 を
    /// 一括ダウンロード等で普通に超えるため引き上げ（2026-07-14 ユーザ確定）。溢れた分は
    /// バッジが付かないだけ（`MaterializedBadge.cappedReport` / `PersistedPathSet.replace` が
    /// 同一規則で決定的に切り詰める = チャーンなし）。
    static let materializedBadgeCap = 10_000

    let s3: TideS3Client
    let cache: ManifestGenerationCache
    /// FP 書込経路（M5 Phase 5-2・deleteItem + modifyItem）。S3 とマニフェストのみを書く。
    let writer: ExtensionWriter
    /// createItem の `.syncignore` 適用（M5 Phase 5-3・案 B = FSEvents モードと同じ除外挙動）。
    /// マニフェスト宣言の `.syncignore` 群を S3 から取得して層状マッチャを組む（世代キー +
    /// sha メモ化キャッシュ）。機密網（`HardcodedIgnoreRules`）は I/O 不要なのでこの外で判定する。
    let ignore: ManifestIgnoreCache
    /// 仮想フォルダ（createItem 仮想受理・マニフェスト非表現）の温存レジストリ（M5 Phase 5-4）。
    /// `item(for:)` / enumerator が合成 dir を返すのはここにあるパスだけ — マニフェスト外の
    /// dir id へ無条件に合成 dir を返すと、dir move/削除の reconcile 中の照会で消えたはずの
    /// 旧 dir が空フォルダとして復活する（5-4 実機 PoC で確定）。
    let virtualDirs: PersistedPathSet
    /// 除外後始末の予約（M5 Phase 5-4）。`ExcludedFromSync` を返した path を登録し、システムが
    /// 「内容ダウンロード → deleteItem」の後始末を発行してきたとき（その baseVersion は sha 形で
    /// ないことを実機観測 = ローカル保留変更の版スタンプ）、**ツリー現行 sha ベースの RMW ガード
    /// 付き削除**として受理する根拠にする。除外以外の deleteItem は従来どおり itemVersion 由来
    /// ベースで裁く（「根拠なしに消さない」の維持）。
    let exclusionCleanups: PersistedPathSet
    /// フォルダを除外名へ改名したときのバッジ凍結の予約（Issue #138・PR #143 レビュー指摘 1）。
    /// 旧フォルダの path を積み、後片付けの deleteItem(dir) が完了するか断るまで、配下のバッジを
    /// 伝え済みのまま凍結する（祖先一致 = `MaterializedBadge.isFrozen`）。削除の受理判定には
    /// 使わない — `exclusionCleanups`（ファイルの受理根拠）と分けておかないと、フォルダの予約を
    /// 外す操作がファイルの予約まで消し、再送された後片付けを断って旧版を S3 に残す。
    let dirCleanupFreezes: PersistedPathSet
    /// フォルダ単位除外の予約（#120 レビュー B1）。仮想フォルダのメタデータ変更（modifyItem）で
    /// 「配下に追跡済みファイルが無い」ことを根拠に `ExcludedFromSync` を返した path を登録し、
    /// 後から届く後始末の deleteItem（dir）を **S3 非接触**で完了させる根拠にする。判定から
    /// 後始末までの間に他端末が配下へ上げたファイルを、後始末が S3 から消さないため。
    let dirExclusionHolds: PersistedPathSet
    /// 実体化バッジ（Issue #65）: Finder へ最後に報告した実体化済みファイルパス集合（永続）。
    /// 前進（replace）させるのは **working set の enumerateChanges のみ**（単一の報告点 —
    /// コンテナ enumerator や書込コールバックが消費すると、working set 経由の差分配信が
    /// 空振りしてバッジが固着する）。move/削除の構造追従（renameSubtree / removeSubtree）は例外。
    let materializedReported: PersistedPathSet
    /// 実体化バッジ（Issue #65）: fileproviderd から最後に観測した live 集合（メモリのみ）。
    let materializedObserver: MaterializedObserver
    /// FP 拡張イベントの共有ログ（Issue #83・fpOnly の Sync Activity 復権）。書込・materialize・
    /// エラー等を App Group Caches の JSONL へ best-effort 追記し、アプリ UI が読んで表示する。
    /// DB 非接触は維持（GRDB 非依存の素のファイル）。書き手はこの拡張プロセスのみ。
    let events: FPEventLog
    /// 実体化バッジ（Issue #65）: live 集合の全量問い合わせ（`MaterializedSetQuery.filePaths`）。
    /// domain を閉じ込めた closure で、`materializedItemsDidChange` と enumerateChanges の
    /// 初回リフレッシュが共用する。失敗は nil（バッジ更新を見送るだけ・安全側）。
    let queryMaterializedFilePaths: @Sendable () async -> Set<String>?
    /// workingSet への自己 signal。現状の呼び手は機会的自己 signal（`onNewGeneration`）のみ。
    /// Phase 5-2 以降の書込通知（拡張自身の書込後にシステムへ変化を取りに来させる）の土台として
    /// 公開している。※「delete 確定 → signal → 新セッションで update」の 2 相配信パターンは
    /// **再導入しないこと** — 22ms 差の別セッションでも ingest 合成で delete が update を打ち消す
    /// ことを実機確定済み（Phase 5-1。kind 変化は id 分離で解決済み・docs/08 参照）。
    let signalWorkingSet: @Sendable () -> Void
    /// rename/reparent 後の版スタンプ自動治癒（Issue #93）: 指定ファイル（相対 POSIX パス）の
    /// reimport をダエモンへ要求する（`reimportItems(below:)`）。ダエモンがディスク上表現を
    /// 再スキャンし createItem(mayAlreadyExist) で問い直してくるので、拡張は同一 sha
    /// ファストパス（`ModifyOutcome.unchanged`・S3 非接触）で生 sha 版 item を返し、
    /// ダエモンの帳簿（版スタンプ）が再構築される = rebind で固着した stale スタンプの治癒。
    /// **`requestDownloadForItem` を使わないこと** — 実体化済み item への要求は acknowledge
    /// されるだけで `isDownloadRequested` も立たず fetchContents も来ない（no-op 扱い）ことを
    /// 実機確定（2026-08-25・フル DL センチネル明示でも同じ。docs/08 #93 節）。
    /// 返値 nil = acknowledge 成功。エラーの解釈（noSuchItem リトライ等）は呼び出し側が担う。
    let requestReimport: @Sendable (String, ManifestTree.Node.Kind) async -> (any Error)?

    /// live 集合を観測し直し、報告済みと食い違えば working set を signal する（Issue #65）。
    /// `materializedItemsDidChange`（materialize / evict の通知）と、enumerateChanges の
    /// 初回リフレッシュ（プロセス起動後まだ didChange が来ていない場合の遅延観測）が共用。
    /// 問い合わせ失敗は何もしない（バッジ更新を見送るだけ・安全側）。
    func refreshMaterializedObservation() async {
        let query = await materializedObserver.beginQuery()
        guard let live = await queryMaterializedFilePaths() else { return }
        await materializedObserver.update(live, query: query)
        let reported = await materializedReported.snapshot()
        if live != reported {
            signalWorkingSet()
        }
    }

    /// Finder へ伝え済みの実体化済みファイル（Issue #138）= 報告済み + 返却 item で伝えた分。
    /// 読み取り経路（item(for:) / enumerateItems / 書込コールバックの返却 item）のファイルの
    /// フラグはこれで引く。dir のフラグは報告済みだけで数える（`BadgeFlags`）。
    func toldMaterialized() async -> (reported: Set<String>, pendingReturned: Set<String>) {
        let reported = await materializedReported.snapshot()
        let pending = await materializedObserver.ledgerSnapshot().pending
        return (reported, pending)
    }

    /// 内容がローカルにあるファイルを返却 item で返すときの実体化フラグ（Issue #138）。
    /// 次の差分配信で報告に入る（上限の内側の）ときだけ true にし、台帳に記録する — 記録しないと
    /// 観測が来るまでの差分配信が同じ item をフラグなしで再送し、版が変わる（バッジのちらつき）。
    func returnedMaterializedFlag(for path: String) async -> Bool {
        let reported = await materializedReported.snapshot()
        let frozen = await frozenBadgePaths()
        return await materializedObserver.noteReturnedIfFits(
            path, reported: reported, frozen: frozen, cap: Self.materializedBadgeCap)
    }

    /// バッジを伝え済みのまま凍結する path（Issue #138）: ファイルの後片付け予約と、フォルダの
    /// 凍結予約の和。フォルダの分は配下ごと凍結する（祖先一致は `MaterializedBadge.isFrozen` 側）。
    func frozenBadgePaths() async -> Set<String> {
        let files = await exclusionCleanups.snapshot()
        let dirs = await dirCleanupFreezes.snapshot()
        return files.union(dirs)
    }

    /// 後片付けの deleteItem(dir) を断ったときに、そのフォルダの凍結予約（Issue #138）だけを外す。
    /// 配下の予約には触れない。凍結中にたまったバッジの変化を配るため working set を signal する
    ///（PR #143 レビュー指摘 4: しないと、ほかの変化が起きるまで配られない）。
    func releaseDirCleanupFreeze(at dirPath: String) async {
        guard await dirCleanupFreezes.contains(dirPath) else { return }
        await dirCleanupFreezes.remove(dirPath)
        signalWorkingSet()
    }

    /// 返却 item のフラグを、台帳に記録せず伝え済みの状態のまま返す（Issue #138）。内容がまだ
    /// ローカルに無い返却 item（modifyItem の競合でリモート版を取り直させる場合）に使う —
    /// 記録すると、内容が来る前に点灯して報告まで進みうる（PR #142 レビュー指摘 8）。
    func toldMaterializedFlag(for path: String) async -> Bool {
        let told = await toldMaterialized()
        return told.reported.contains(path) || told.pendingReturned.contains(path)
    }

    /// 単一ファイルの move に実体化バッジの状態（報告済み・live・返却分の台帳）を追従させる。
    /// 単一ファイルの rename は id rebind で実体化ごと維持される（実機確定）ので live も動かす。
    /// dir の move は配下が dataless になる（Phase 5-4 パスベース id の帰結）ので使わない。
    func followMaterializedFileMove(from: String, to: String) async {
        await materializedReported.renameSubtree(from: from, to: to)
        await materializedObserver.renameSubtree(from: from, to: to)
    }

    /// 削除に実体化バッジの状態（報告済み・live・返却分の台帳）を追従させる。
    func followMaterializedRemoval(at path: String) async {
        await materializedReported.removeSubtree(at: path)
        await materializedObserver.removeSubtree(at: path)
    }

    /// 共有設定から構築する。未セットアップ / 認証情報なしなら nil
    /// （呼び出し側が `NSFileProviderError(.notAuthenticated)` に落とす）。
    /// ログは診断のため既定レベル以上（notice/error = 永続）で出す — 拡張プロセスは
    /// 対話デバッグしづらく、`log show` で追えることが重要（Phase 3 実機デバッグの教訓）。
    /// - Parameter domain: 機会的自己 signal（キャッシュ更新が新世代 = リモート変化を検知した
    ///   ときの `signalEnumerator(.workingSet)`）の宛先。
    static func fromSharedConfig(domain: NSFileProviderDomain) -> ExtensionServices? {
        let config = ConfigStore()  // 既定 = App Group 共有 suite
        let hasBucket = !(config.bucketName ?? "").isEmpty
        let hasRegion = !(config.region ?? "").isEmpty
        AppLogger.fileProvider.notice("Extension config check: setupCompleted=\(config.setupCompleted) bucket=\(hasBucket) region=\(hasRegion)")
        guard config.setupCompleted, hasBucket, hasRegion,
              let bucket = config.bucketName, let region = config.region else {
            AppLogger.fileProvider.notice("Extension not configured (setup incomplete)")
            return nil
        }
        let credentials: AWSCredentials?
        do {
            credentials = try KeychainStore().load()
        } catch {
            AppLogger.fileProvider.error("Extension: Keychain read failed: \(String(describing: error), privacy: .private)")
            return nil
        }
        guard let credentials else {
            AppLogger.fileProvider.error("Extension: AWS credentials not found in shared Keychain")
            return nil
        }
        // プロセス内で共有する（Issue #151）: fileproviderd は同じプロセスの中で拡張のインスタンスを
        // 作り直し、見限った古いインスタンスが処理中の書込を抱えたまま新しいインスタンスと同居する
        // ことがある。インスタンスごとにサービスを作ると、index の更新をまとめる仕組み
        // （`IndexUpdateCoalescer`）・キャッシュ・レジストリ（同じ JSON）が別物になり、互いに
        // index.json を奪い合って index が古いまま残った（2026-10-31 実機）。構築に使う値（ドメイン・
        // epoch・設定・認証情報）がすべて同じなら、前に作ったものを返す。どれかが変われば作り直す
        // （設定画面での帯域・上限の変更、認証情報の入れ替え、ドメインの作り直しを取りこぼさない）。
        let key = SharingKey(
            domainIdentifier: domain.identifier.rawValue,
            domainEpoch: config.fileProviderDomainEpoch,
            bucket: bucket, region: region, deviceId: config.deviceId,
            credentials: credentials,
            uploadSizeLimitBytes: config.uploadSizeLimitBytes,
            uploadBandwidthBytesPerSec: config.uploadBandwidthBytesPerSec)
        let boxedDomain = UncheckedSendableBox(value: domain)
        return shared.withLockUnchecked { cached -> ExtensionServices? in
            if let cached, cached.key == key {
                AppLogger.fileProvider.notice("Extension: reusing shared services in this process")
                return cached.services
            }
            guard let built = build(
                domain: boxedDomain.value, config: config, credentials: credentials,
                bucket: bucket, region: region, domainEpoch: key.domainEpoch)
            else { return nil }
            cached = (key, built)
            return built
        }
    }

    /// プロセス内で共有しているサービスと、それを作った値（Issue #151）。
    private static let shared = OSAllocatedUnfairLock<(key: SharingKey, services: ExtensionServices)?>(
        initialState: nil)

    /// サービスの構築に使う値。すべて同じときだけ共有したものを使い回す。
    private struct SharingKey: Equatable, Sendable {
        let domainIdentifier: String
        let domainEpoch: String?
        let bucket: String
        let region: String
        let deviceId: String
        let credentials: AWSCredentials
        let uploadSizeLimitBytes: Int64
        let uploadBandwidthBytesPerSec: Int64
    }

    private static func build(
        domain: NSFileProviderDomain, config: ConfigStore, credentials: AWSCredentials,
        bucket: String, region: String, domainEpoch: String?
    ) -> ExtensionServices? {
        do {
            let s3 = try TideS3Client(
                credentials: credentials, region: region, bucket: bucket,
                deviceId: config.deviceId
            )
            let logURL = try? ManifestGenerationLog.defaultURL()
            if logURL == nil {
                AppLogger.fileProvider.error("Extension: generation log URL unavailable (persisting disabled)")
            }
            // NSFileProviderDomain は Sendable 注釈が無いが、signalEnumerator は
            // どのスレッド/プロセスから呼んでもよい契約なので箱で closure へ運ぶ。
            let boxedDomain = UncheckedSendableBox(value: domain)
            let signalWorkingSet: @Sendable () -> Void = {
                // replicated 拡張への signal は .workingSet のみ有効（他は無視される）。
                NSFileProviderManager(for: boxedDomain.value)?.signalEnumerator(for: .workingSet) { error in
                    if let error {
                        AppLogger.fileProvider.error("Self-signal failed: \(String(describing: error), privacy: .private)")
                    }
                }
            }
            let requestReimport: @Sendable (String, ManifestTree.Node.Kind) async -> (any Error)? = { path, kind in
                guard let manager = NSFileProviderManager(for: boxedDomain.value) else {
                    return NSFileProviderError(.providerNotFound)
                }
                do {
                    try await manager.reimportItems(
                        below: NSFileProviderItemIdentifier(tideRelativePath: path, kind: kind))
                    return nil
                } catch {
                    return error
                }
            }
            let cache = ManifestGenerationCache(
                loader: ManifestSnapshotLoader(source: s3),
                bucket: bucket,
                logURL: logURL,
                onNewGeneration: {
                    // ブラウズ契機のリフレッシュがリモート変化に気づいた時の自己 signal。
                    // アプリ側の pull 後 signal が主経路で、これはアプリ非起動時の補完。
                    // Phase 5-2 の自世代 append（recordLocalChange）もここを通る =
                    // 拡張自身の書込の anchor 前進もこの 1 本に集約。
                    signalWorkingSet()
                }
            )
            // 拡張の ManifestUpdater は onManifestDidWrite を**明示 nil**にする: 拡張の signal は
            // 書込後の `invalidateAfterLocalWrite` → onNewGeneration が担う。ここでも発火させると
            // 「無効化前の signal → enumerateChanges → 旧世代ロード」の無駄往復になる
            // （アプリ側は世代ログを持たないため書込確定点の hook が signal の正位置、という
            // 役割分担。docs/08 Phase 5-2 節参照）。
            let writer = ExtensionWriter(
                s3: s3,
                cache: cache,
                updater: ManifestUpdater(store: s3, deviceId: config.deviceId, onManifestDidWrite: nil),
                deviceId: config.deviceId,
                uploadSizeLimitBytes: config.uploadSizeLimitBytes,
                uploadLimiter: RateLimiter(ratePerSec: Double(config.uploadBandwidthBytesPerSec))
            )
            let ignore = ManifestIgnoreCache { path, versionId, maxPrefixBytes in
                // `.syncignore` 本体の取得。path はマニフェスト（リモート）由来なので S3 キー
                // 組み立て前に必ず検証する。sha256 は**全バイト**から計算しつつ、保持は先頭
                // maxPrefixBytes のみ（超過分は打ち切りパース = アプリ側の読込打ち切りと同じ）。
                // 404 / NoSuchVersion は nil（呼び出し側が最新版フォールバック / 層スキップ）。
                try PathValidator.validateRelativePath(path)
                var hasher = SHA256()
                var prefix = Data()
                let result = try await s3.streamObject(
                    key: "files/\(path)", versionId: versionId, rangeStart: nil
                ) { chunk in
                    hasher.update(data: chunk)
                    if prefix.count < maxPrefixBytes {
                        prefix.append(chunk.prefix(maxPrefixBytes - prefix.count))
                    }
                }
                guard result != nil else { return nil }
                return .init(sha256: HashCalculator.hex(hasher.finalize()), prefix: prefix)
            }
            let virtualDirsURL = try? PersistedPathSet.defaultURL(
                filename: "fileprovider-virtual-dirs.json")
            let cleanupsURL = try? PersistedPathSet.defaultURL(
                filename: "fileprovider-exclusion-cleanups.json")
            let materializedURL = try? PersistedPathSet.defaultURL(
                filename: "fileprovider-materialized.json")
            let dirHoldsURL = try? PersistedPathSet.defaultURL(
                filename: "fileprovider-dir-exclusion-holds.json")
            let dirFreezesURL = try? PersistedPathSet.defaultURL(
                filename: "fileprovider-dir-cleanup-freezes.json")
            if virtualDirsURL == nil || cleanupsURL == nil || materializedURL == nil
                || dirHoldsURL == nil || dirFreezesURL == nil {
                AppLogger.fileProvider.error("Extension: path-set registry URL unavailable (persisting disabled)")
            }
            // ドメイン epoch（Issue #104）: アプリがドメイン除去のたびに進める世代値をここで
            // 一度だけ capture し、レジストリ 5 本の payload スタンプ / 読込検証に使う。
            // ドメイン作り直しを跨いだ stale レジストリ（バッジ永久不点灯・消えた dir の合成・
            // 無意味な削除受理予約）は epoch 不一致で読込時に全体破棄される。プロセス生存中に
            // アプリが bump しても capture 値は変えない — 遅延 persist は旧 epoch でスタンプされ
            // 次プロセスが破棄する（`PersistedPathSet` の capture 意味論）。値は共有のキーに入れたもの
            // （同じ読み取り）を使う = キーとレジストリの epoch が食い違わない（Issue #151）。
            // capture 値の観測点（PR #106 レビュー指摘 5）: group defaults のプロセス間伝播に
            // タイミング保証は無く、stale capture が起きるとバッジ不点灯 / 仮想フォルダ消失の
            // 症状から本機構へ辿れない。アプリ側の bump ログと突合できるよう notice（永続）で
            // 残す。値はローカル生成のランダム UUID = 機密性なし（.public で相関可能に）。
            AppLogger.fileProvider.notice("Extension: captured domain epoch \(domainEpoch ?? "none", privacy: .public)")
            let eventsURL = try? FPEventLog.defaultURL()
            if eventsURL == nil {
                AppLogger.fileProvider.error("Extension: event log URL unavailable (activity logging disabled)")
            }
            return ExtensionServices(
                s3: s3, cache: cache, writer: writer, ignore: ignore,
                virtualDirs: PersistedPathSet(
                    bucket: bucket, fileURL: virtualDirsURL, epoch: domainEpoch),
                exclusionCleanups: PersistedPathSet(
                    bucket: bucket, fileURL: cleanupsURL, epoch: domainEpoch),
                dirCleanupFreezes: PersistedPathSet(
                    bucket: bucket, fileURL: dirFreezesURL, epoch: domainEpoch),
                dirExclusionHolds: PersistedPathSet(
                    bucket: bucket, fileURL: dirHoldsURL, epoch: domainEpoch),
                materializedReported: PersistedPathSet(
                    bucket: bucket, fileURL: materializedURL, epoch: domainEpoch,
                    maxEntries: Self.materializedBadgeCap),
                materializedObserver: MaterializedObserver(),
                events: FPEventLog(bucket: bucket, fileURL: eventsURL),
                queryMaterializedFilePaths: {
                    await MaterializedSetQuery.filePaths(domain: boxedDomain.value)
                },
                signalWorkingSet: signalWorkingSet,
                requestReimport: requestReimport
            )
        } catch {
            AppLogger.fileProvider.error("Extension: failed to construct S3 client: \(String(describing: error), privacy: .private)")
            return nil
        }
    }
}
