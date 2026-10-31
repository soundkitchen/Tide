import TideCore
import Foundation

/// fpOnly: FP 拡張のイベントログ（`FPEventLog`）の新着のうち、通知の印（`FPEventNotice`）が
/// 付いたものを OS 通知へつなぐ（Issue #147 / #148）。
///
/// - 拡張は追記のたびに Darwin 通知（`FPEventLog.defaultChangeNotificationName`）を送り、受けたら
///   新着を読む（Issue #148）。通知を取りこぼしたときの保険として、間隔をあけた定期の確認も残す。
///   読むのは前回読んだ位置から先の新着だけ（`FPEventLog.readNew`）。
/// - どこまで通知したかの位置（カーソル）は種類で 2 本に分ける（PR #149 レビュー指摘 2）:
///   - fileproviderd が再送する種類（作成時の除外・サイズ超過・書込の失敗）: 起動した時点から。起動前の
///     分は通知しない（起動直後にまとめて出さない・ユーザ確定）。止まっていた間の分も、再送されたときに知らせる。
///   - 再送されない種類（改名の除外・競合コピー）: 位置を `ConfigStore.fpNoticeCursor` に保存し、
///     アプリが止まっていた間の分も次の起動で知らせる（再送されないので、ここで逃すと二度と出ない）。
///     保存が無いとき（初回・factoryReset 後）は起動時刻から始める。
/// - 再送される種類は、同じアイテムを起動中に 1 回だけ通知する。記録はメモリだけに持つ
///   （2026-10-28 ユーザ確定）ので、アプリを再起動すると、再送されたものをもう一度知らせる。
///   記録が上限（`maxNotifiedKeys`）に達したら空にする（常駐中に際限なく増やさない・指摘 7）。
/// - 書込の失敗（`writeFailed`）は 1 回では知らせない。同じパスで続いた回数を数え、
///   `failureThreshold` 回に達したら 1 回知らせる（folderSync の give-up に当たる・#148）。
///   そのパスの書込が成功した記録（作成・更新・移動・削除・競合コピー）で数え直す。回数は起動前の
///   記録も数えるが、知らせるのは起動後の失敗で回数に達したときだけ（起動直後にまとめて出さない）。
/// - 1 回の確認で多数出るとき（symlink を多く含むフォルダを入れた等）は、バックアップされない出来事・
///   失敗が続く出来事それぞれで最初の `individualLimit` 件だけ個別に出し、残りを「ほか N 件」の 1 件に
///   まとめる（指摘 1）。競合コピーはまとめない（1 件ずつ手で直す必要がある）。
///
/// 取りこぼしうる場合（どちらも通知が 1 件欠けるだけ・同期には影響しない）:
/// - 前回読んだあとに 2 回以上ローテーションした（読まないまま 2MB 以上たまった）とき、失われた世代。
/// - タイムスタンプが同じ値のイベントの片方だけを先に読んだ場合（マイクロ秒単位で同時の書込）。
/// - 時計が戻ったとき、戻る前に進めたカーソルに追いつくまでの新着（カーソルは壁時計の時刻）。
@MainActor
final class FPEventNoticeWatcher {
    /// 1 回の確認で個別に出す通知の上限。超えた分は「ほか N 件」の 1 件にまとめる。
    nonisolated static let individualLimit = 3
    /// 再送される種類の「通知済み」の記録・失敗の回数の記録の上限。
    nonisolated static let maxNotifiedKeys = 10_000
    /// 書込の失敗が同じパスで何回続いたら知らせるか（folderSync の give-up と同じ・ユーザ確定 2026-10-31）。
    nonisolated static let failureThreshold = 5

    /// 2 本のカーソル（上の型コメント参照）。
    struct Cursors: Equatable {
        /// 再送される種類用。起動時刻から始める。
        var sinceLaunch: Double
        /// 再送されない種類用。保存した位置から始める。
        var saved: Double
    }

    /// 確認をまたいで持つ記録（メモリだけ）。
    struct State: Equatable {
        /// 再送される種類のうち、通知済みのもの（`"<種類>:<表示パス>"`）。
        var notified: Set<String> = []
        /// 書込の失敗が続いている回数（表示パス → 回数）。成功の記録で消す。
        var failureCounts: [String: Int] = [:]
    }

    private let readNew: @Sendable (FPEventLog.ReadPosition?) async
        -> (records: [FPEventRecord], position: FPEventLog.ReadPosition?)
    private let saveCursor: (Double) -> Void
    private let post: (NotificationEvent) -> Void
    /// 追記の通知を受け取る登録を作る（返した値を手放すと受け取りをやめる）。nil = 登録できない。
    private let observeChanges: (@escaping @Sendable () -> Void) -> AnyObject?
    private let intervalSeconds: Int

    private var cursors: Cursors
    private var state = State()
    /// ログをどこまで読んだか（nil = まだ読んでいない = 初回は全部読む）。
    private var position: FPEventLog.ReadPosition?
    private var isChecking = false
    /// 確認の途中で次の確認を頼まれた（その間の追記を読み逃さないよう、終わったらもう一度読む）。
    private var recheckRequested = false
    private var pollTask: Task<Void, Never>?
    private var observation: AnyObject?

    init(
        intervalSeconds: Int = 60,
        startedAt: Date = Date(),
        savedCursor: Double?,
        readNew: @escaping @Sendable (FPEventLog.ReadPosition?) async
            -> (records: [FPEventRecord], position: FPEventLog.ReadPosition?),
        saveCursor: @escaping (Double) -> Void,
        post: @escaping (NotificationEvent) -> Void,
        observeChanges: @escaping (@escaping @Sendable () -> Void) -> AnyObject? = { _ in nil }
    ) {
        let launch = startedAt.timeIntervalSince1970
        self.intervalSeconds = intervalSeconds
        self.cursors = Cursors(sinceLaunch: launch, saved: savedCursor ?? launch)
        self.readNew = readNew
        self.saveCursor = saveCursor
        self.post = post
        self.observeChanges = observeChanges
    }

    convenience init(log: FPEventLog, config: ConfigStore, post: @escaping (NotificationEvent) -> Void) {
        self.init(
            savedCursor: config.fpNoticeCursor,
            readNew: { await log.readNew(since: $0) },
            saveCursor: { config.fpNoticeCursor = $0 },
            post: post,
            observeChanges: { FPEventLog.observeChanges(handler: $0) }
        )
    }

    func start() {
        stop()
        // 拡張の追記の通知を受けたら読む
        observation = observeChanges {
            Task { @MainActor [weak self] in await self?.checkOnce() }
        }
        if observation == nil {
            AppLogger.ui.error("FP event notices: falling back to periodic checks only")
        }
        // 初回はすぐに確認する（止まっていた間の改名・競合コピーを、起動直後に知らせるため）
        Task { [weak self] in await self?.checkOnce() }
        let interval = intervalSeconds
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                await self?.checkOnce()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        observation = nil
    }

    deinit {
        pollTask?.cancel()
    }

    /// 1 回分の確認（テストから直接駆動する）。確認の途中で頼まれたら、終わったあとにもう一度読む。
    func checkOnce() async {
        if isChecking {
            recheckRequested = true
            return
        }
        isChecking = true
        defer { isChecking = false }
        repeat {
            recheckRequested = false
            await readAndPost()
        } while recheckRequested
    }

    private func readAndPost() async {
        let (records, next) = await readNew(position)
        position = next
        guard !records.isEmpty else { return }
        let result = Self.notices(in: records, after: cursors, state: &state)
        if result.cursors.saved != cursors.saved {
            saveCursor(result.cursors.saved)
        }
        cursors = result.cursors
        for event in Self.batched(result.events) {
            post(event)
        }
    }

    /// 書込の成功の記録（失敗の回数を数え直す）。
    private nonisolated static let successEventTypes: Set<String> = [
        SyncLogEventType.upload.rawValue, SyncLogEventType.delete.rawValue,
        SyncLogEventType.move.rawValue, SyncLogEventType.conflict.rawValue,
    ]

    /// カーソルより新しいレコードから通知する出来事を取り出し、進めたカーソルと一緒に返す
    /// （副作用は `state` の更新だけ・`FPEventNoticeWatcherTests` で全分岐を固定）。
    /// どちらのカーソルも、印の有無にかかわらず、読んだ中で最も新しいタイムスタンプまで進める。
    nonisolated static func notices(
        in records: [FPEventRecord], after cursors: Cursors, state: inout State,
        maxNotifiedKeys: Int = FPEventNoticeWatcher.maxNotifiedKeys,
        failureThreshold: Int = FPEventNoticeWatcher.failureThreshold
    ) -> (events: [NotificationEvent], cursors: Cursors) {
        var events: [NotificationEvent] = []
        var next = cursors
        for record in records {
            next.sinceLaunch = max(next.sinceLaunch, record.timestamp)
            next.saved = max(next.saved, record.timestamp)
            if successEventTypes.contains(record.eventType), let path = record.path {
                state.failureCounts[path] = nil
                state.notified.remove("\(FPEventNotice.writeFailed.rawValue):\(path)")
            }
            guard let raw = record.notice, let notice = FPEventNotice(rawValue: raw),
                  let subject = notice.subject(of: record), !subject.isEmpty
            else { continue }
            if notice.isCountedFailure {
                if state.failureCounts[subject] == nil, state.failureCounts.count >= maxNotifiedKeys {
                    state.failureCounts.removeAll()
                }
                let count = (state.failureCounts[subject] ?? 0) + 1
                state.failureCounts[subject] = count
                guard count >= failureThreshold else { continue }
            }
            if notice.isResentByDaemon {
                guard record.timestamp > cursors.sinceLaunch else { continue }
                if state.notified.count >= maxNotifiedKeys { state.notified.removeAll() }
                guard state.notified.insert("\(notice.rawValue):\(subject)").inserted else { continue }
            } else {
                guard record.timestamp > cursors.saved else { continue }
            }
            events.append(event(for: notice, subject: subject, record: record))
        }
        return (events, next)
    }

    /// 印 → 通知の出来事。
    nonisolated static func event(
        for notice: FPEventNotice, subject: String, record: FPEventRecord
    ) -> NotificationEvent {
        switch notice {
        case .conflictCopyCreated:
            // 退避先は details（拡張が入れる）。通知の本文には出さない（名前は正規のパス）。
            return .conflictCopyCreated(path: subject, localCopyPath: record.details ?? "")
        case .fileTooLarge:
            return .fileTooLarge(path: subject)
        case .writeFailed:
            return .writeKeepsFailing(path: subject)
        case .unsyncableName, .symbolicLink, .renamedFileExcluded, .renamedFolderExcluded,
             .packageHasUnsyncableItem, .packageTooManyFiles:
            return .notBackedUp(path: subject, reason: notice)
        }
    }

    /// 多数の通知を、まとめる組ごとに最初の `limit` 件と「ほか N 件」の 1 件にまとめる。
    /// まとめない出来事（競合コピー）はそのまま。組ごとに `limit` 件以下ならそのまま。
    nonisolated static func batched(
        _ events: [NotificationEvent], limit: Int = FPEventNoticeWatcher.individualLimit
    ) -> [NotificationEvent] {
        var result: [NotificationEvent] = []
        var notBackedUp = 0
        var keepsFailing = 0
        for event in events {
            switch event {
            case .notBackedUp, .fileTooLarge:
                notBackedUp += 1
                if notBackedUp <= limit { result.append(event) }
            case .writeKeepsFailing:
                keepsFailing += 1
                if keepsFailing <= limit { result.append(event) }
            default:
                result.append(event)
            }
        }
        if notBackedUp > limit { result.append(.notBackedUpMore(count: notBackedUp - limit)) }
        if keepsFailing > limit { result.append(.writeKeepsFailingMore(count: keepsFailing - limit)) }
        return result
    }
}
