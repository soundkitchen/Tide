import Foundation

/// UI に見せる同期エラーの構造化表現（F4 / H2 UI 残の解消）。
/// 旧 `recentErrors: [String]` の後継で、既定表示は分類サマリ（`category` のローカライズ）に限定し、
/// 生のエラー文字列（`rawDetail`）はオンデマンドのコピー / 詳細表示でのみ参照する。
struct SyncIssue: Identifiable, Equatable, Sendable {
    /// エラーの分類。判定は `SyncIssueClassifier`（純粋関数）に一本化する。
    enum Category: String, CaseIterable, Sendable {
        case network          // URLError / タイムアウト / オフライン
        case accessDenied     // S3 403（IAM 権限不足）
        case notFound         // S3 404（バケット / キー / バージョン不在）
        case remoteConflict   // 412 / 409（マニフェスト楽観ロック・並行書込衝突）
        case fileTooLarge     // アップロードサイズ上限超過（恒久・Settings で調整）
        case unstableFile     // 読込中に変化し続ける（L6 A-detect の延期）
        case localIO          // ローカル FS の読み書き失敗
        case database         // ローカル DB（GRDB）失敗
        case configuration    // 未設定 / syncRoot 不正 / バージョニング無効 / Keychain
        case unsafePath       // リモート由来の不正パスを拒否（PathValidator）
        case other
    }

    let id: UUID
    let date: Date
    /// 関連する相対パス（無いエラーもある: pull 全体の失敗など）。
    let path: String?
    let category: Category
    /// `String(describing: error)` 全文。既定では表示せず、コピー / 詳細展開でのみ見せる。
    let rawDetail: String
}

extension SyncIssue.Category {
    /// ポップオーバー / ステータス行に出す短い分類サマリ。
    var localizedLabel: String {
        switch self {
        case .network:        return String(localized: "Network error")
        case .accessDenied:   return String(localized: "Access denied")
        case .notFound:       return String(localized: "Not found on S3")
        case .remoteConflict: return String(localized: "Remote write conflict")
        case .fileTooLarge:   return String(localized: "File too large")
        case .unstableFile:   return String(localized: "File keeps changing")
        case .localIO:        return String(localized: "Local file error")
        case .database:       return String(localized: "Database error")
        case .configuration:  return String(localized: "Configuration error")
        case .unsafePath:     return String(localized: "Unsafe remote path rejected")
        case .other:          return String(localized: "Sync error")
        }
    }

    /// ユーザが次に取れる行動の指針（無いカテゴリは nil）。
    var localizedGuidance: String? {
        switch self {
        case .network:
            return String(localized: "Will retry when the connection recovers.")
        case .accessDenied:
            return String(localized: "Check the IAM policy for the bucket.")
        case .remoteConflict:
            return String(localized: "Another device may be syncing; usually resolves on retry.")
        case .fileTooLarge:
            return String(localized: "Not backed up. Increase the upload size limit in Settings.")
        case .unstableFile:
            return String(localized: "Not backed up yet. It will be uploaded once it stops changing.")
        case .configuration:
            return String(localized: "Run Setup again to fix the configuration.")
        case .notFound, .localIO, .database, .unsafePath, .other:
            return nil
        }
    }

    /// メニューバーのカテゴリ別グルーピングで使う SF Symbols 名。
    var symbolName: String {
        switch self {
        case .network:        return "wifi.exclamationmark"
        case .accessDenied:   return "lock.slash"
        case .notFound:       return "questionmark.folder"
        case .remoteConflict: return "arrow.triangle.2.circlepath.circle"
        case .fileTooLarge:   return "externaldrive.badge.exclamationmark"
        case .unstableFile:   return "clock.arrow.circlepath"
        case .localIO:        return "doc.badge.gearshape"
        case .database:       return "cylinder.split.1x2"
        case .configuration:  return "gearshape.2"
        case .unsafePath:     return "exclamationmark.shield"
        case .other:          return "exclamationmark.circle"
        }
    }
}
