import Foundation

/// 進行中の 1 転送の進捗（メニューバーのポップオーバー表示用）。
/// `direction` は `TransferDirection`（`transfer_state` と共通）を流用する。
struct TransferProgress: Identifiable, Equatable, Sendable {
    let path: String
    let direction: TransferDirection
    var transferredBytes: Int64
    var totalBytes: Int64

    var id: String { "\(direction.rawValue):\(path)" }

    /// 0...1。totalBytes が 0 のときは 0（ゼロ除算回避）。
    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(transferredBytes) / Double(totalBytes)))
    }
}

/// 転送の進捗イベント。off-main の Uploader / Downloader が発行し、`SyncEngine` が MainActor で集約する。
enum TransferProgressEvent: Sendable {
    case begin(path: String, direction: TransferDirection, totalBytes: Int64)
    case update(path: String, direction: TransferDirection, transferredBytes: Int64)
    case end(path: String, direction: TransferDirection)
}

/// 進捗を報告するためのシンク。`@Sendable` なので off-main のタスクから安全に呼べる
/// （実体は `SyncEngine` が MainActor へホップして `activeTransfers` を更新する）。
typealias TransferProgressReporter = @Sendable (TransferProgressEvent) -> Void
