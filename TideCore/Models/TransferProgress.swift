import Foundation

/// 進行中の 1 転送の進捗（メニューバーのポップオーバー表示用）。
/// `direction` は `TransferDirection`（`transfer_state` と共通）を流用する。
public struct TransferProgress: Identifiable, Equatable, Sendable {
    public let path: String
    public let direction: TransferDirection
    public var transferredBytes: Int64
    public var totalBytes: Int64

    public init(path: String, direction: TransferDirection, transferredBytes: Int64, totalBytes: Int64) {
        self.path = path
        self.direction = direction
        self.transferredBytes = transferredBytes
        self.totalBytes = totalBytes
    }

    public var id: String { "\(direction.rawValue):\(path)" }

    /// 0...1。totalBytes が 0 のときは 0（ゼロ除算回避）。
    public var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(transferredBytes) / Double(totalBytes)))
    }
}

/// 転送の進捗イベント。off-main の Uploader / Downloader が発行し、`SyncEngine` が MainActor で集約する。
public enum TransferProgressEvent: Sendable {
    case begin(path: String, direction: TransferDirection, totalBytes: Int64)
    case update(path: String, direction: TransferDirection, transferredBytes: Int64)
    case end(path: String, direction: TransferDirection)
}

/// 進捗を報告するためのシンク。`@Sendable` なので off-main のタスクから安全に呼べる
/// （実体は `SyncEngine` が MainActor へホップして `activeTransfers` を更新する）。
public typealias TransferProgressReporter = @Sendable (TransferProgressEvent) -> Void

extension TransferProgress {
    /// 進捗イベントを現在のリストへ適用した新リストを返す（純粋関数）。
    ///
    /// reporter が生む Task の到着順は前後し得るため、out-of-order 耐性を持たせる:
    /// - `begin`: (path, direction) のエントリを作成（既存なら total のみ更新）。
    /// - `update`: **既存エントリの増加方向のみ**適用（不在＝end 済み or begin 前なら no-op＝復活させない）。
    /// - `end`: 該当エントリを除去。
    public static func reduce(
        _ transfers: [TransferProgress],
        applying event: TransferProgressEvent
    ) -> [TransferProgress] {
        var list = transfers
        switch event {
        case let .begin(path, direction, total):
            if let i = list.firstIndex(where: { $0.path == path && $0.direction == direction }) {
                list[i].totalBytes = total
            } else {
                list.append(TransferProgress(
                    path: path, direction: direction, transferredBytes: 0, totalBytes: total
                ))
            }
        case let .update(path, direction, transferred):
            if let i = list.firstIndex(where: { $0.path == path && $0.direction == direction }),
               transferred > list[i].transferredBytes {
                list[i].transferredBytes = transferred
            }
        case let .end(path, direction):
            list.removeAll { $0.path == path && $0.direction == direction }
        }
        return list
    }
}
