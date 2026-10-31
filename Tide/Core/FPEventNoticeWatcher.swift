import TideCore
import Foundation

/// fpOnly: FP 拡張のイベントログ（`FPEventLog`）の新着のうち、通知の印（`FPEventNotice`）が
/// 付いたものを OS 通知へつなぐ（Issue #147）。
///
/// - 拡張からアプリへ伝える手段は共有ログしかないため、一定間隔でログを見に行く。読むのは
///   前回読んだ位置から先の新着だけ（`FPEventLog.readNew`・Issue #148）。
/// - どこまで通知したかの位置（カーソル）は種類で 2 本に分ける（PR #149 レビュー指摘 2）:
///   - 作成時の除外（fileproviderd が再送する種類）: 起動した時点から。起動前の分は通知しない
///     （起動直後にまとめて出さない・ユーザ確定）。止まっていた間の分も、再送されたときに知らせる。
///   - 改名の除外（再送されない種類）: 位置を `ConfigStore.fpNoticeRenameCursor` に保存し、
///     アプリが止まっていた間の改名も次の起動で知らせる（再送されないので、ここで逃すと二度と出ない）。
///     保存が無いとき（初回・factoryReset 後）は起動時刻から始める。
/// - 再送される種類は、同じアイテムを起動中に 1 回だけ通知する。記録はメモリだけに持つ
///   （2026-10-28 ユーザ確定）ので、アプリを再起動すると、再送されたものをもう一度知らせる。
///   記録が上限（`maxNotifiedKeys`）に達したら空にする（常駐中に際限なく増やさない・指摘 7）。
/// - 1 回の確認で多数出るとき（symlink を多く含むフォルダを入れた等）は、最初の
///   `individualLimit` 件だけ個別に出し、残りを「ほか N 件」の 1 件にまとめる（指摘 1）。
/// - 他の出来事も印を足せば載る形にしてある（#148 で競合コピー等を載せる予定）。
///
/// 取りこぼしうる場合（どちらも通知が 1 件欠けるだけ・同期には影響しない）:
/// - 前回読んだあとに 2 回以上ローテーションした（読まないまま 2MB 以上たまった）とき、失われた世代。
/// - タイムスタンプが同じ値のイベントの片方だけを先に読んだ場合（マイクロ秒単位で同時の書込）。
/// - 時計が戻ったとき、戻る前に進めたカーソルに追いつくまでの新着（カーソルは壁時計の時刻）。
@MainActor
final class FPEventNoticeWatcher {
    /// 1 回の確認で個別に出す通知の上限。超えた分は「ほか N 件」の 1 件にまとめる。
    nonisolated static let individualLimit = 3
    /// 再送される種類の「通知済み」の記録の上限。
    nonisolated static let maxNotifiedKeys = 10_000

    /// 2 本のカーソル（上の型コメント参照）。
    struct Cursors: Equatable {
        /// 作成時の除外（再送される種類）用。起動時刻から始める。
        var created: Double
        /// 改名の除外（再送されない種類）用。保存した位置から始める。
        var renamed: Double
    }

    private let readNew: @Sendable (FPEventLog.ReadPosition?) async
        -> (records: [FPEventRecord], position: FPEventLog.ReadPosition?)
    private let saveRenamedCursor: (Double) -> Void
    private let post: (NotificationEvent) -> Void
    private let intervalSeconds: Int

    private var cursors: Cursors
    /// 再送される種類のうち、通知済みのもの（`"<種類>:<表示パス>"`）。
    private var notifiedKeys: Set<String> = []
    /// ログをどこまで読んだか（nil = まだ読んでいない = 初回は全部読む）。
    private var position: FPEventLog.ReadPosition?
    private var isChecking = false
    private var pollTask: Task<Void, Never>?

    init(
        intervalSeconds: Int = 5,
        startedAt: Date = Date(),
        savedRenamedCursor: Double?,
        readNew: @escaping @Sendable (FPEventLog.ReadPosition?) async
            -> (records: [FPEventRecord], position: FPEventLog.ReadPosition?),
        saveRenamedCursor: @escaping (Double) -> Void,
        post: @escaping (NotificationEvent) -> Void
    ) {
        let launch = startedAt.timeIntervalSince1970
        self.intervalSeconds = intervalSeconds
        self.cursors = Cursors(created: launch, renamed: savedRenamedCursor ?? launch)
        self.readNew = readNew
        self.saveRenamedCursor = saveRenamedCursor
        self.post = post
    }

    convenience init(log: FPEventLog, config: ConfigStore, post: @escaping (NotificationEvent) -> Void) {
        self.init(
            savedRenamedCursor: config.fpNoticeRenameCursor,
            readNew: { await log.readNew(since: $0) },
            saveRenamedCursor: { config.fpNoticeRenameCursor = $0 },
            post: post
        )
    }

    func start() {
        stop()
        // 初回はすぐに確認する（止まっていた間の改名を、起動直後に知らせるため）
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
    }

    deinit {
        pollTask?.cancel()
    }

    /// 1 回分の確認（テストから直接駆動する）。
    func checkOnce() async {
        if isChecking { return }
        isChecking = true
        defer { isChecking = false }

        let (records, next) = await readNew(position)
        position = next
        guard !records.isEmpty else { return }
        let result = Self.notices(in: records, after: cursors, notified: &notifiedKeys)
        if result.cursors.renamed != cursors.renamed {
            saveRenamedCursor(result.cursors.renamed)
        }
        cursors = result.cursors
        for event in Self.batched(result.events) {
            post(event)
        }
    }

    /// カーソルより新しいレコードから通知する出来事を取り出し、進めたカーソルと一緒に返す
    /// （副作用は `notified` の更新だけ・`FPEventNoticeWatcherTests` で全分岐を固定）。
    /// どちらのカーソルも、印の有無にかかわらず、読んだ中で最も新しいタイムスタンプまで進める。
    nonisolated static func notices(
        in records: [FPEventRecord], after cursors: Cursors, notified: inout Set<String>,
        maxNotifiedKeys: Int = FPEventNoticeWatcher.maxNotifiedKeys
    ) -> (events: [NotificationEvent], cursors: Cursors) {
        var events: [NotificationEvent] = []
        var next = cursors
        for record in records {
            next.created = max(next.created, record.timestamp)
            next.renamed = max(next.renamed, record.timestamp)
            guard let raw = record.notice, let notice = FPEventNotice(rawValue: raw),
                  let subject = notice.subject(of: record), !subject.isEmpty
            else { continue }
            if notice.isResentByDaemon {
                guard record.timestamp > cursors.created else { continue }
                if notified.count >= maxNotifiedKeys { notified.removeAll() }
                guard notified.insert("\(notice.rawValue):\(subject)").inserted else { continue }
            } else {
                guard record.timestamp > cursors.renamed else { continue }
            }
            events.append(.notBackedUp(path: subject, reason: notice))
        }
        return (events, next)
    }

    /// 多数の通知を、最初の `limit` 件と「ほか N 件」の 1 件にまとめる。`limit` 件以下ならそのまま。
    nonisolated static func batched(
        _ events: [NotificationEvent], limit: Int = FPEventNoticeWatcher.individualLimit
    ) -> [NotificationEvent] {
        guard events.count > limit else { return events }
        return Array(events.prefix(limit)) + [.notBackedUpMore(count: events.count - limit)]
    }
}
