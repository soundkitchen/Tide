import TideCore
import Foundation

/// fpOnly: FP 拡張のイベントログ（`FPEventLog`）の新着のうち、通知の印（`FPEventNotice`）が
/// 付いたものを OS 通知へつなぐ（Issue #147）。
///
/// - 拡張からアプリへ伝える手段は共有ログしかないため、一定間隔でログを見に行く。ログが
///   変わったかはまず stat の署名（`FPEventLog.changeSignature`）で確かめ、変わったときだけ読む。
/// - 起動した時点より前のイベントは通知しない（起動直後にまとめて出さない）。
/// - fileproviderd が除外を再送する種類（`FPEventNotice.isResentByDaemon`・#120 の再送嵐）は、
///   同じアイテムを起動中に 1 回だけ通知する。記録はメモリだけに持つ（2026-10-28 ユーザ確定）ので、
///   アプリを再起動すると、再送されたものをもう一度知らせる。
/// - 他の出来事も印を足せば載る形にしてある（#148 で競合コピー等を載せる予定）。
///
/// 取りこぼしうる場合（どちらも通知が 1 件欠けるだけ・同期には影響しない）:
/// - `loadRecords()` の `.1` と現行の読み取りの合間に拡張がローテーションすると、その 1 回だけ
///   旧現行の世代が欠けて見え、カーソルがそれより新しいイベントまで進む（ローテーションは 2MB ごと）。
/// - タイムスタンプが同じ値のイベントの片方だけを先に読んだ場合（マイクロ秒単位で同時の書込）。
@MainActor
final class FPEventNoticeWatcher {
    private let loadRecords: @Sendable () async -> [FPEventRecord]
    private let changeSignature: @Sendable () -> String
    private let post: (NotificationEvent) -> Void
    private let intervalSeconds: Int

    /// これより新しいタイムスタンプのイベントだけを通知する（起動時刻から始める）。
    private var cursor: Double
    /// 再送される種類のうち、通知済みのもの（`"<種類>:<表示パス>"`）。
    private var notifiedKeys: Set<String> = []
    private var lastSignature: String?
    private var isChecking = false
    private var pollTask: Task<Void, Never>?

    init(
        intervalSeconds: Int = 5,
        startedAt: Date = Date(),
        loadRecords: @escaping @Sendable () async -> [FPEventRecord],
        changeSignature: @escaping @Sendable () -> String,
        post: @escaping (NotificationEvent) -> Void
    ) {
        self.intervalSeconds = intervalSeconds
        self.cursor = startedAt.timeIntervalSince1970
        self.loadRecords = loadRecords
        self.changeSignature = changeSignature
        self.post = post
    }

    convenience init(log: FPEventLog, post: @escaping (NotificationEvent) -> Void) {
        self.init(
            loadRecords: { await log.loadRecords() },
            changeSignature: { log.changeSignature() },
            post: post
        )
    }

    func start() {
        stop()
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

        let signature = changeSignature()
        guard signature != lastSignature else { return }
        lastSignature = signature

        let records = await loadRecords()
        let result = Self.notices(in: records, after: cursor, notified: &notifiedKeys)
        cursor = result.cursor
        for event in result.events {
            post(event)
        }
    }

    /// `cursor` より新しいレコードから通知する出来事を取り出し、進めたカーソルと一緒に返す
    /// （副作用は `notified` の更新だけ・`FPEventNoticeWatcherTests` で全分岐を固定）。
    /// カーソルは印の有無にかかわらず、読んだ中で最も新しいタイムスタンプまで進める。
    nonisolated static func notices(
        in records: [FPEventRecord], after cursor: Double, notified: inout Set<String>
    ) -> (events: [NotificationEvent], cursor: Double) {
        var events: [NotificationEvent] = []
        var newCursor = cursor
        for record in records where record.timestamp > cursor {
            newCursor = max(newCursor, record.timestamp)
            guard let raw = record.notice, let notice = FPEventNotice(rawValue: raw),
                  let subject = notice.subject(of: record), !subject.isEmpty
            else { continue }
            if notice.isResentByDaemon {
                guard notified.insert("\(notice.rawValue):\(subject)").inserted else { continue }
            }
            events.append(.notBackedUp(path: subject, reason: notice))
        }
        return (events, newCursor)
    }
}
