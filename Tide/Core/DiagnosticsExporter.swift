import TideCore
import Foundation

/// 診断情報（アプリ/OS バージョン・設定の要約・最近の sync_log・DB スナップショット）を
/// 1 つの .zip にまとめて書き出す。ベータテスターが問題報告に添付できるようにする導線。
///
/// 【セキュリティ不変条件】AWS 認証情報（Keychain）は **一切扱わない**。入力は ConfigStore の
/// 非機密フィールドと sync_log / DB のみ。ただし DB スナップショットと sync_log には
/// **同期フォルダ配下のファイル名/相対パス・バケット名・deviceId が含まれる**（診断目的で必要）。
/// 認証情報は含まないがこれらは含む旨を、UI 文言と diagnostics.txt の Note で明示する。
/// 出力先は NSSavePanel でユーザが選んだ場所のみ。
enum DiagnosticsExporter {

    /// 診断テキストの素材（テスト可能にするため値だけ受け取る純粋型）。
    /// ここに AWS アクセスキー等のシークレットは含めない（構造的に漏れない）。
    struct Inputs: Sendable {
        var appVersion: String
        var appBuild: String
        var osVersion: String
        var deviceId: String
        var bucket: String?
        var region: String?
        var syncRootPath: String?
        var uploadSizeLimitBytes: Int64
        var notificationsEnabled: Bool
        var queueDepth: Int?
        var logCount: Int
        var generatedAt: Date
    }

    // MARK: - 純粋なテキスト組み立て（テスト可能）

    /// 人間可読の診断テキストを組み立てる純粋関数。シークレットは入力に無い＝出力にも出ない。
    static func diagnosticsText(_ i: Inputs) -> String {
        let limit = i.uploadSizeLimitBytes < 0
            ? "No limit"
            : "\(i.uploadSizeLimitBytes / (1024 * 1024 * 1024)) GB"
        var lines: [String] = []
        lines.append("Tide Diagnostics")
        lines.append("Generated: \(ISO8601DateFormatter().string(from: i.generatedAt))")
        lines.append("App version: \(i.appVersion) (build \(i.appBuild))")
        lines.append("macOS: \(i.osVersion)")
        lines.append("Device ID: \(i.deviceId)")
        lines.append("Bucket: \(i.bucket ?? "—")")
        lines.append("Region: \(i.region ?? "—")")
        lines.append("Sync folder: \(i.syncRootPath ?? "—")")
        lines.append("Upload size limit: \(limit)")
        lines.append("Notifications: \(i.notificationsEnabled ? "enabled" : "disabled")")
        lines.append("Queue depth: \(i.queueDepth.map(String.init) ?? "—")")
        lines.append("Recent log entries: \(i.logCount)")
        lines.append("")
        lines.append("Note: This export INCLUDES file names/paths under your sync folder, the bucket name, region, and device ID (needed for troubleshooting).")
        lines.append("AWS credentials are stored in the macOS Keychain and are NOT included.")
        return lines.joined(separator: "\n") + "\n"
    }

    /// sync_log をテキスト化（DB 内は英語の生文字列なのでそのまま出す）。新しい順。
    static func logText(_ records: [SyncLogRecord]) -> String {
        guard !records.isEmpty else { return "(no log entries)\n" }
        let fmt = ISO8601DateFormatter()
        return records.map { r in
            let ts = fmt.string(from: Date(timeIntervalSince1970: r.timestamp))
            var line = "\(ts)  [\(r.eventType)]"
            if let p = r.path { line += "  \(p)" }
            line += "  \(r.message)"
            if let d = r.details, !d.isEmpty { line += "  — \(d)" }
            return line
        }.joined(separator: "\n") + "\n"
    }

    // MARK: - 書き出し（IO）

    /// 診断 zip を `destination` に書き出す。最近の sync_log（最大 `logLimit` 件）と DB スナップショットを同梱する。
    /// MainActor 上では env から非機密の値を集めるだけで、重い IO（log 取得・staging 書き出し・
    /// スナップショット・zip 化）は `writeArchive`（nonisolated）でメインアクター外に出す
    /// （CLAUDE.md「重い処理はメインから外す」。手動・低頻度操作でも UI を塞がない）。
    @MainActor
    static func export(to destination: URL, env: AppEnvironment, logLimit: Int = 1000) async throws {
        // logCount は writeArchive 側で実 sync_log 件数に確定する（ここでは 0 プレースホルダ）。
        let inputs = Inputs(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            deviceId: env.config.deviceId,
            bucket: env.config.bucketName,
            region: env.config.region,
            // #97: fpOnly（engine 不在）では値を渡さず "—" 表示（死にキーの削除済みパスを診断へ
            // 出さない）。folderSync デッド経路が生きる revert 時のみ従来どおりパスが載る。
            syncRootPath: env.engine != nil ? env.config.syncRootPath : nil,
            uploadSizeLimitBytes: env.config.uploadSizeLimitBytes,
            notificationsEnabled: env.config.notificationsEnabled,
            queueDepth: env.engine?.queueDepth,
            logCount: 0,
            generatedAt: Date()
        )
        try await writeArchive(inputs: inputs, db: env.database, logLimit: logLimit, to: destination)
    }

    /// 重い IO 部分（sync_log 取得・staging 書き出し・DB スナップショット・zip 化）を
    /// メインアクター外で実行する。`db` は @unchecked Sendable・`inputs` は Sendable 値なので安全に渡せる。
    /// テストからも直接呼べる（env 非依存）。
    nonisolated static func writeArchive(
        inputs: Inputs, db: LocalDatabase?, logLimit: Int, to destination: URL
    ) async throws {
        // sync_log を取得（DB が無い＝未設定でも診断テキストだけは出す）
        let logs: [SyncLogRecord]
        if let db {
            logs = (try? await db.fetchLogs(limit: logLimit))?.records ?? []
        } else {
            logs = []
        }
        var inputs = inputs
        inputs.logCount = logs.count

        let fm = FileManager.default
        // zip 展開時の最上位フォルダ名を「Tide-Diagnostics」に固定するため、UUID は親側に付ける
        // （staging 自体を UUID 名にすると展開フォルダが乱数名になる）。
        let parent = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let staging = parent.appendingPathComponent("Tide-Diagnostics", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: parent) }

        try diagnosticsText(inputs).write(
            to: staging.appendingPathComponent("diagnostics.txt"), atomically: true, encoding: .utf8)
        try logText(logs).write(
            to: staging.appendingPathComponent("sync-log.txt"), atomically: true, encoding: .utf8)

        // DB スナップショット（一貫コピー）。失敗しても診断テキスト/ログは残す。
        if let db {
            try? await db.snapshot(to: staging.appendingPathComponent("db.sqlite"))
        }

        // ステージングを zip 化（NSFileCoordinator の .forUploading は依存無しでディレクトリを zip 化する）
        try zipDirectory(staging, to: destination)
    }

    /// ディレクトリを zip 化して `destination` に置く。NSFileCoordinator(.forUploading) が
    /// 一時 zip を作るので、それを destination にコピーする（既存があれば上書き）。
    private static func zipDirectory(_ directory: URL, to destination: URL) throws {
        let fm = FileManager.default
        var coordError: NSError?
        var ioError: Error?
        NSFileCoordinator().coordinate(readingItemAt: directory, options: .forUploading, error: &coordError) { zipped in
            do {
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                try fm.copyItem(at: zipped, to: destination)
            } catch {
                ioError = error
            }
        }
        if let coordError { throw coordError }
        if let ioError { throw ioError }
    }
}
