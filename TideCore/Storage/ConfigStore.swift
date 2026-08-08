import Foundation

/// アプリ設定の永続化（UserDefaults ベース）。認証情報は別途 KeychainStore。
public final class ConfigStore: @unchecked Sendable {
    private let defaults: UserDefaults

    private enum Key {
        static let bucketName = "tide.bucketName"
        static let region = "tide.region"
        static let syncRootPath = "tide.syncRootPath"
        static let deviceId = "tide.deviceId"
        static let pollingIntervalSeconds = "tide.pollingIntervalSeconds"
        static let setupCompleted = "tide.setupCompleted"
        static let uploadSizeLimitBytes = "tide.uploadSizeLimitBytes"
        static let uploadBandwidthBytesPerSec = "tide.uploadBandwidthBytesPerSec"
        static let downloadBandwidthBytesPerSec = "tide.downloadBandwidthBytesPerSec"
        static let notificationsEnabled = "tide.notificationsEnabled"
        static let syncRootBookmark = "tide.syncRootBookmark"
        static let syncMode = "tide.syncMode"
    }

    /// 稼働モードの列挙。**v0.3.0（#96）以降、アプリはこの値で分岐しない**（boot は無条件
    /// fpOnly）。rawValue は外部ツール契約の一部（下記 `syncMode` プロパティの doc 参照）。
    /// - `folderSync`: 旧 FSEvents モード（`SyncEngine` = 同期フォルダ監視 + pull + アップロード）。
    ///   **到達不能の温存デッドコード**であり、生きた選択肢ではない。復活は git revert のみ
    ///   （docs/09「revert 復帰ランブック」の遵守必須）。UI / 分岐へ再配線してはならない
    ///   （空フォルダ受理 → S3 一斉 delete marker の事故窓が再び開く。docs/09 v0.3.0 節）。
    /// - `fpOnly`: File Provider のみで稼働（現行唯一のモード）。アプリは `SyncEngine` を起動せず
    ///   `RemoteChangeSignaler`（index HEAD ETag 比較）だけを立ち上げる。
    ///   DB / syncRoot / bookmark は凍結温存（revert 復帰時に通常 pull が差分を取り込む）。
    public enum SyncMode: String, Sendable, CaseIterable {
        case folderSync
        case fpOnly
    }

    /// 1 ファイルあたりのアップロードサイズ上限の既定値（1 GiB）。
    public static let defaultUploadSizeLimitBytes: Int64 = 1 * 1024 * 1024 * 1024

    /// `LegacyStateMigrator` が旧ロケーションの defaults から group suite へコピーするキー一覧。
    /// deviceId を含む（マニフェスト上のデバイス識別を移行後も維持する）。
    /// syncRootBookmark も含む: 移行は常に**同一マシン内**の世代移動なので bookmark は有効なまま
    /// （運ばないと移行のたびに再許可パネルが出る）。`SettingsTransfer`（別マシンへ渡りうる）には
    /// Payload にフィールドが無く構造的に含まれない。
    public static let migratableKeys: [String] = [
        Key.bucketName, Key.region, Key.syncRootPath, Key.deviceId,
        Key.pollingIntervalSeconds, Key.setupCompleted,
        Key.uploadSizeLimitBytes,
        Key.uploadBandwidthBytesPerSec, Key.downloadBandwidthBytesPerSec,
        Key.notificationsEnabled, Key.syncRootBookmark,
        Key.syncMode
    ]

    /// セットアップ完了フラグの defaults キー（`LegacyStateMigrator` の移行要否判定用）。
    public static var setupCompletedDefaultsKey: String { Key.setupCompleted }

    /// 既定は App Group 共有 suite（M5 Phase 2 で標準 defaults から移設）。
    /// 旧 standard defaults からの一度きり移行は `LegacyStateMigrator` が行う。
    public init(defaults: UserDefaults = TideAppGroup.sharedDefaults()) {
        self.defaults = defaults
    }

    public var bucketName: String? {
        get { defaults.string(forKey: Key.bucketName) }
        set { defaults.set(newValue, forKey: Key.bucketName) }
    }

    public var region: String? {
        get { defaults.string(forKey: Key.region) }
        set { defaults.set(newValue, forKey: Key.region) }
    }

    /// 同期フォルダのパス。**書くときは `syncRootBookmark` と対で更新すること**
    /// （不変条件・PR #49 再レビュー #2）: `resolveSyncRootAccess` は「両者の乖離＝外部リネーム由来」
    /// を前提に bookmark が指す実体へパスを追随させるため、bookmark を伴わずここだけ書き換えると
    /// 次回起動で旧フォルダのパスへ黙って巻き戻される。v0.3.0（#97）で `completeSetup` は書かなく
    /// なり、両キーは folderSync デッド経路の温存（正規の書き手は `resolveSyncRootAccess` の
    /// 追随更新のみ・到達は git revert のみ = docs/09 v0.3.0 節）。
    public var syncRootPath: String? {
        get { defaults.string(forKey: Key.syncRootPath) }
        set { defaults.set(newValue, forKey: Key.syncRootPath) }
    }

    public var pollingIntervalSeconds: Int {
        get {
            let v = defaults.integer(forKey: Key.pollingIntervalSeconds)
            // 0 = 未設定 → 既定 180。明示値は下限 30 へクランプ: 負値/極小値が保存されていると
            // `Task.sleep(for: .seconds(負))` が即時 return し、SyncEngine の pull /
            // RemoteChangeSignaler の HEAD が密ループ化する（PR #75 レビュー任意 2）。
            return v == 0 ? 180 : max(30, v)
        }
        set { defaults.set(newValue, forKey: Key.pollingIntervalSeconds) }
    }

    public var setupCompleted: Bool {
        get { defaults.bool(forKey: Key.setupCompleted) }
        set { defaults.set(newValue, forKey: Key.setupCompleted) }
    }

    /// 1 ファイルあたりのアップロードサイズ上限（バイト）。
    /// `-1` = 無制限。キー未設定（`0`）のときは既定値（1 GiB）を返す（`pollingIntervalSeconds` と同じ流儀）。
    /// この上限はアップロード方向のみに適用し、ダウンロード（復元）は常に許可する。
    public var uploadSizeLimitBytes: Int64 {
        get {
            // キー未設定なら既定値。`0` を「未設定」と「明示的な 0」の両義で使わないよう、
            // presence（`object(forKey:)`）で判定する（-1=無制限などの明示値はそのまま尊重）。
            guard defaults.object(forKey: Key.uploadSizeLimitBytes) != nil else {
                return Self.defaultUploadSizeLimitBytes
            }
            return Int64(defaults.integer(forKey: Key.uploadSizeLimitBytes))
        }
        set { defaults.set(Int(newValue), forKey: Key.uploadSizeLimitBytes) }
    }

    /// アップロードの帯域上限（bytes/sec）。`<= 0` = 無制限。既定（キー未設定）は無制限（`-1`）。
    /// この上限は file 本体の転送（`files/*`）だけに効き、マニフェスト・シャード等の小さな
    /// メタデータ PUT/GET には掛けない。Uploader が周回ごとに読み直して反映する。
    public var uploadBandwidthBytesPerSec: Int64 {
        get {
            guard defaults.object(forKey: Key.uploadBandwidthBytesPerSec) != nil else { return -1 }
            return Int64(defaults.integer(forKey: Key.uploadBandwidthBytesPerSec))
        }
        set { defaults.set(Int(newValue), forKey: Key.uploadBandwidthBytesPerSec) }
    }

    /// ダウンロード（復元）の帯域上限（bytes/sec）。`<= 0` = 無制限。既定は無制限（`-1`）。
    public var downloadBandwidthBytesPerSec: Int64 {
        get {
            guard defaults.object(forKey: Key.downloadBandwidthBytesPerSec) != nil else { return -1 }
            return Int64(defaults.integer(forKey: Key.downloadBandwidthBytesPerSec))
        }
        set { defaults.set(Int(newValue), forKey: Key.downloadBandwidthBytesPerSec) }
    }

    /// 競合発生・未バックアップ確定（サイズ超過 / give-up / 不安定）を OS 通知で知らせるか。
    /// キー未設定なら既定 on（オプトアウト方式）。実際に通知を出すかは OS の許可状態にも従う。
    public var notificationsEnabled: Bool {
        get {
            guard defaults.object(forKey: Key.notificationsEnabled) != nil else { return true }
            return defaults.bool(forKey: Key.notificationsEnabled)
        }
        set { defaults.set(newValue, forKey: Key.notificationsEnabled) }
    }

    /// 同期フォルダの security-scoped bookmark（App Sandbox 下での再アクセス手段・M5 Phase 2）。
    /// セットアップ時（パネル選択）に発行し、bootstrap が解決して scoped アクセスを開始する。
    /// デバイス固有バイナリだが、`LegacyStateMigrator` の移行は同一マシン内の世代移動なので
    /// `migratableKeys` に含める（別マシンへ渡りうる `SettingsTransfer` には構造的に含まれない）。
    public var syncRootBookmark: Data? {
        get { defaults.data(forKey: Key.syncRootBookmark) }
        set { defaults.set(newValue, forKey: Key.syncRootBookmark) }
    }

    /// 稼働モードの保存値 = **外部ツール契約キー**（v0.3.0 / #96 で転生）。アプリ自身は分岐の
    /// ために**読まない** — boot は無条件 fpOnly で、`AppEnvironment.bootstrap` が正規化書込
    /// （`!= .fpOnly` なら fpOnly を書く）を行うため保存値は恒久 fpOnly。folderSync へ戻す手段は
    /// git revert のみ（docs/09「revert 復帰ランブック」参照）。
    /// 読み手は `tools/soak/consistency_check.py` の 4 箇所:
    /// (a) `--fp-only` 無し実行を exit 2 で止める突合ガード (b) DB 凍結見張り（`DBFreezeWatch`）の
    /// 武装条件 (c) `mode:switched` WARN（起動時値とのズレ）(d) `mode:config-mismatch` WARN
    /// （`--fp-only` × 実モード非 fpOnly で毎周回）。キー廃止は観測の静かな縮退になるため不可。
    /// 未知の保存値は `folderSync` へフォールバック（＝正規化書込の対象になり fpOnly へ戻る）。
    /// `reset()`（factoryReset / 再セットアップ）はキーを一時削除する — `completeSetup` 冒頭の
    /// 明示書込（#96 で前倒し実装済み・#97 のシグネチャ置換でも維持すること）が不在窓を閉じる。
    /// `SettingsTransfer` にはフィールドが無く構造的に含まれない
    /// （マシン固有の運用値のため持ち出さない）。
    public var syncMode: SyncMode {
        get { SyncMode(rawValue: defaults.string(forKey: Key.syncMode) ?? "") ?? .folderSync }
        set { defaults.set(newValue.rawValue, forKey: Key.syncMode) }
    }

    /// 初回アクセス時に UUID を自動生成して保存する。以降不変。
    public var deviceId: String {
        if let existing = defaults.string(forKey: Key.deviceId), !existing.isEmpty {
            return existing
        }
        let host = (Host.current().localizedName ?? "Mac")
            .replacingOccurrences(of: " ", with: "-")
        let suffix = UUID().uuidString.prefix(8)
        let id = "\(host)-\(suffix)"
        defaults.set(id, forKey: Key.deviceId)
        return id
    }

    /// 接続情報を消すが deviceId は残す。
    /// キー一覧は `migratableKeys` から導出して二重管理を避ける（PR #49 レビュー #6）。
    /// 差分は deviceId（reset では残す）のみ。
    public func reset() {
        for key in Self.migratableKeys where key != Key.deviceId {
            defaults.removeObject(forKey: key)
        }
    }

    /// deviceId も含めて完全に消す（factoryReset 用）。
    public func resetIncludingDeviceId() {
        reset()
        defaults.removeObject(forKey: Key.deviceId)
    }
}
