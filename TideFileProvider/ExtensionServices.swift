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
        guard let live = await queryMaterializedFilePaths() else { return }
        await materializedObserver.update(live)
        let reported = await materializedReported.snapshot()
        if live != reported {
            signalWorkingSet()
        }
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
            if virtualDirsURL == nil || cleanupsURL == nil || materializedURL == nil {
                AppLogger.fileProvider.error("Extension: path-set registry URL unavailable (persisting disabled)")
            }
            let eventsURL = try? FPEventLog.defaultURL()
            if eventsURL == nil {
                AppLogger.fileProvider.error("Extension: event log URL unavailable (activity logging disabled)")
            }
            return ExtensionServices(
                s3: s3, cache: cache, writer: writer, ignore: ignore,
                virtualDirs: PersistedPathSet(bucket: bucket, fileURL: virtualDirsURL),
                exclusionCleanups: PersistedPathSet(bucket: bucket, fileURL: cleanupsURL),
                materializedReported: PersistedPathSet(
                    bucket: bucket, fileURL: materializedURL,
                    maxEntries: Self.materializedBadgeCap),
                materializedObserver: MaterializedObserver(),
                events: FPEventLog(bucket: bucket, fileURL: eventsURL),
                queryMaterializedFilePaths: {
                    await MaterializedSetQuery.filePaths(domain: boxedDomain.value)
                },
                signalWorkingSet: signalWorkingSet
            )
        } catch {
            AppLogger.fileProvider.error("Extension: failed to construct S3 client: \(String(describing: error), privacy: .private)")
            return nil
        }
    }
}
