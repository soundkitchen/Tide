import CryptoKit
import FileProvider
import Foundation
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
    /// 10,000 では、ツリーのファイル（2026-11-01 で 11,671 件）をほぼ全部実体化すると溢れ、パス昇順で
    /// 後ろに並ぶファイルとフォルダにチェックが付かなかった。報告に入るのはツリーにあるファイルだけ
    /// なので、ツリーより大きくしておけば溢れない。100,000 に上げた（Issue #141・ユーザ確定。
    /// レジストリの JSON は最大で約 9MB）。
    static let materializedBadgeCap = 100_000

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
            dropSharedConnection()
            return nil
        }
        let credentials: AWSCredentials?
        do {
            credentials = try KeychainStore().load()
        } catch {
            // 読み取りの一時的な失敗では、共有の接続（② / ③）を外さない（Issue #158）。外すと次の
            // インスタンスが ② を作り直し、書込を抱えた古いインスタンスと同じプロセスにコアレッサと
            // キャッシュが 2 つでき、index.json を奪い合う（#151 と同じ構図）。このインスタンスは
            // nil（notAuthenticated）を返す。
            AppLogger.fileProvider.error("Extension: Keychain read failed: \(String(describing: error), privacy: .private)")
            return nil
        }
        guard let credentials else {
            AppLogger.fileProvider.error("Extension: AWS credentials not found in shared Keychain")
            dropSharedConnection()
            return nil
        }
        // プロセス内で共有する（Issue #151）: fileproviderd は同じプロセスの中で拡張のインスタンスを
        // 作り直し、見限った古いインスタンスが処理中の書込を抱えたまま新しいインスタンスと同居する
        // ことがある。インスタンスごとにサービスを作ると、index の更新をまとめる仕組み
        // （`IndexUpdateCoalescer`）・キャッシュ・レジストリ（同じ JSON）が別物になり、互いに
        // index.json を奪い合って index が古いまま残った（2026-10-31 実機）。サービスを 3 段
        // （状態 / 接続 / 書き手）に分け、変わった値の段とその下の段だけを作り直す
        // （`FileProviderServiceSharing`）。値はここで 1 度だけ読み、キーと構築の両方に使う
        // （読み直すと、キーが作った値を表さなくなる・PR #157 レビュー指摘 3）。
        let deviceId = config.deviceId
        let key = FileProviderServiceSharing.Key(
            state: .init(
                domainIdentifier: domain.identifier.rawValue,
                domainEpoch: config.fileProviderDomainEpoch, bucket: bucket),
            connection: .init(
                region: region, deviceId: deviceId,
                credentialsDigest: FileProviderServiceSharing.credentialsDigest(credentials)),
            writer: .init(
                uploadSizeLimitBytes: config.uploadSizeLimitBytes,
                uploadBandwidthBytesPerSec: config.uploadBandwidthBytesPerSec))

        sharedLock.lock()
        defer { sharedLock.unlock() }
        let reuseState = shared?.stateKey == key.state
        let plan = FileProviderServiceSharing.plan(cached: shared?.connected?.key, new: key)
        let state: SharedState
        if reuseState, let cached = shared?.state {
            state = cached
        } else {
            state = makeState(domain: domain, key: key.state)
        }
        let connection: SharedConnection
        if reuseState, plan.reuseConnection, let cached = shared?.connected?.connection {
            connection = cached
        } else {
            guard let built = makeConnection(
                bucket: bucket, region: region, deviceId: deviceId,
                credentials: credentials, signalWorkingSet: state.signalWorkingSet)
            else {
                shared = SharedEntry(stateKey: key.state, state: state, connected: nil)
                return nil
            }
            connection = built
        }
        let writer: ExtensionWriter
        if reuseState, plan.reuseWriter, let cached = shared?.connected?.writer {
            writer = cached
        } else {
            writer = ExtensionWriter(
                s3: connection.s3,
                cache: connection.cache,
                updater: connection.updater,
                deviceId: deviceId,
                uploadSizeLimitBytes: key.writer.uploadSizeLimitBytes,
                uploadLimiter: RateLimiter(ratePerSec: Double(key.writer.uploadBandwidthBytesPerSec))
            )
        }
        let reuseConnection = reuseState && plan.reuseConnection
        let reuseWriter = reuseState && plan.reuseWriter
        AppLogger.fileProvider.notice("Extension: shared services in this process: state=\(reuseState ? "reused" : "built", privacy: .public) connection=\(reuseConnection ? "reused" : "built", privacy: .public) writer=\(reuseWriter ? "reused" : "built", privacy: .public)")
        shared = SharedEntry(
            stateKey: key.state, state: state,
            connected: SharedConnected(key: key, connection: connection, writer: writer))
        return ExtensionServices(
            s3: connection.s3, cache: connection.cache, writer: writer, ignore: connection.ignore,
            virtualDirs: state.virtualDirs,
            exclusionCleanups: state.exclusionCleanups,
            dirCleanupFreezes: state.dirCleanupFreezes,
            dirExclusionHolds: state.dirExclusionHolds,
            materializedReported: state.materializedReported,
            materializedObserver: state.materializedObserver,
            events: state.events,
            queryMaterializedFilePaths: state.queryMaterializedFilePaths,
            signalWorkingSet: state.signalWorkingSet
        )
    }

    // MARK: - プロセス内の共有（Issue #151）

    /// 段 ①: 状態。ドメイン・epoch・バケットが同じ限り作り直さない — レジストリ（同じ JSON）を
    /// 別々の actor が読み書きすると、互いの追加（除外の予約など）を上書きで落としうる。
    private struct SharedState: Sendable {
        let virtualDirs: PersistedPathSet
        let exclusionCleanups: PersistedPathSet
        let dirCleanupFreezes: PersistedPathSet
        let dirExclusionHolds: PersistedPathSet
        let materializedReported: PersistedPathSet
        let materializedObserver: MaterializedObserver
        let events: FPEventLog
        let queryMaterializedFilePaths: @Sendable () async -> Set<String>?
        let signalWorkingSet: @Sendable () -> Void
    }

    /// 段 ②: S3 への接続。認証情報・deviceId・リージョンが変わったときだけ作り直す。
    private struct SharedConnection: Sendable {
        let s3: TideS3Client
        let cache: ManifestGenerationCache
        /// 書込の `ManifestUpdater`。中の `IndexUpdateCoalescer` を書き手の作り直しを跨いで共有する。
        let updater: ManifestUpdater
        let ignore: ManifestIgnoreCache
    }

    /// 段 ② と ③（認証情報を持つ段）。設定が欠けたときはこれだけを外す（PR #157 レビュー指摘 5）。
    private struct SharedConnected: Sendable {
        let key: FileProviderServiceSharing.Key
        let connection: SharedConnection
        let writer: ExtensionWriter
    }

    private struct SharedEntry: Sendable {
        let stateKey: FileProviderServiceSharing.StateKey
        let state: SharedState
        let connected: SharedConnected?
    }

    /// 共有の置き場。構築（S3 クライアント・App Group コンテナの解決など）を握ったまま行うので、
    /// 短い区間向けの unfair lock ではなく NSLock で守る（PR #157 レビュー指摘 2）。
    private static let sharedLock = NSLock()
    nonisolated(unsafe) private static var shared: SharedEntry?

    /// 設定が欠けたとき（factoryReset のあと・認証情報が無いとき）、認証情報を持つ段を置き場から
    /// 外す。状態の段は残す（認証情報を持たず、設定が戻ったときに同じものを使い回す）。
    /// Keychain の読み取りの一時的な失敗では呼ばない（Issue #158）。
    private static func dropSharedConnection() {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        guard let entry = shared, entry.connected != nil else { return }
        shared = SharedEntry(stateKey: entry.stateKey, state: entry.state, connected: nil)
    }

    private static func makeState(
        domain: NSFileProviderDomain, key: FileProviderServiceSharing.StateKey
    ) -> SharedState {
        // NSFileProviderDomain は Sendable 注釈が無いが、signalEnumerator は
        // どのスレッド/プロセスから呼んでもよい契約なので箱で closure へ運ぶ。
        // 共有の段はドメインの識別子が同じ限り使い回すので、最初に作ったインスタンスの
        // domain をそのまま持つ（NSFileProviderManager(for:) が引くのは識別子）。
        let boxedDomain = UncheckedSendableBox(value: domain)
        let signalWorkingSet: @Sendable () -> Void = {
            // replicated 拡張への signal は .workingSet のみ有効（他は無視される）。
            NSFileProviderManager(for: boxedDomain.value)?.signalEnumerator(for: .workingSet) { error in
                if let error {
                    AppLogger.fileProvider.error("Self-signal failed: \(String(describing: error), privacy: .private)")
                }
            }
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
        // 無意味な削除受理予約）は epoch 不一致で読込時に全体破棄される。作ったレジストリの
        // capture 値は変えない — 遅延 persist は旧 epoch でスタンプされ次プロセスが破棄する
        // （`PersistedPathSet` の capture 意味論）。epoch は共有のキーに入っているので、アプリが
        // bump したあとに来たインスタンスには新しい epoch の状態の段を作る（Issue #151）。
        // capture 値の観測点（PR #106 レビュー指摘 5）: group defaults のプロセス間伝播に
        // タイミング保証は無く、stale capture が起きるとバッジ不点灯 / 仮想フォルダ消失の
        // 症状から本機構へ辿れない。アプリ側の bump ログと突合できるよう notice（永続）で
        // 残す。値はローカル生成のランダム UUID = 機密性なし（.public で相関可能に）。
        let domainEpoch = key.domainEpoch
        AppLogger.fileProvider.notice("Extension: captured domain epoch \(domainEpoch ?? "none", privacy: .public)")
        let eventsURL = try? FPEventLog.defaultURL()
        if eventsURL == nil {
            AppLogger.fileProvider.error("Extension: event log URL unavailable (activity logging disabled)")
        }
        let bucket = key.bucket
        return SharedState(
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
            // 追記のたびにアプリへ Darwin 通知を送る（Issue #148・アプリの通知の見張りが受けて新着を読む）
            events: FPEventLog(
                bucket: bucket, fileURL: eventsURL,
                changeNotificationName: FPEventLog.defaultChangeNotificationName),
            queryMaterializedFilePaths: {
                await MaterializedSetQuery.filePaths(domain: boxedDomain.value)
            },
            signalWorkingSet: signalWorkingSet
        )
    }

    private static func makeConnection(
        bucket: String, region: String, deviceId: String, credentials: AWSCredentials,
        signalWorkingSet: @escaping @Sendable () -> Void
    ) -> SharedConnection? {
        let s3: TideS3Client
        do {
            s3 = try TideS3Client(
                credentials: credentials, region: region, bucket: bucket, deviceId: deviceId)
        } catch {
            AppLogger.fileProvider.error("Extension: failed to construct S3 client: \(String(describing: error), privacy: .private)")
            return nil
        }
        let logURL = try? ManifestGenerationLog.defaultURL()
        if logURL == nil {
            AppLogger.fileProvider.error("Extension: generation log URL unavailable (persisting disabled)")
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
        let updater = ManifestUpdater(store: s3, deviceId: deviceId, onManifestDidWrite: nil)
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
        return SharedConnection(s3: s3, cache: cache, updater: updater, ignore: ignore)
    }
}
