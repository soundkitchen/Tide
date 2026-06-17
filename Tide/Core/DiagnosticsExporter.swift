import Foundation

/// 診断情報（アプリ/OS バージョン・設定の要約・最近の sync_log・DB スナップショット）を
/// 1 つの .zip にまとめて書き出す。ベータテスターが問題報告に添付できるようにする導線。
///
/// 【セキュリティ不変条件】AWS 認証情報（Keychain）は **一切扱わない**。入力は ConfigStore の
/// 非機密フィールドと sync_log のみで、いずれもシークレットを含まない。診断テキストにも
/// 「認証情報は含まれない」旨を明記する。出力先は NSSavePanel でユーザが選んだ場所のみ。
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
        lines.append("Note: AWS credentials are stored in the macOS Keychain and are NOT included in this export.")
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
    @MainActor
    static func export(to destination: URL, env: AppEnvironment, logLimit: Int = 1000) async throws {
        // 1) sync_log を取得（DB が無い＝未設定でも診断テキストだけは出す）
        let logs: [SyncLogRecord]
        if let db = env.database {
            logs = (try? await db.fetchLogs(limit: logLimit))?.records ?? []
        } else {
            logs = []
        }

        // 2) 診断テキストの素材を集める（すべて非機密）
        let inputs = Inputs(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            deviceId: env.config.deviceId,
            bucket: env.config.bucketName,
            region: env.config.region,
            syncRootPath: env.config.syncRootPath,
            uploadSizeLimitBytes: env.config.uploadSizeLimitBytes,
            notificationsEnabled: env.config.notificationsEnabled,
            queueDepth: env.engine?.queueDepth,
            logCount: logs.count,
            generatedAt: Date()
        )

        // 3) ステージングディレクトリにファイルを書き出す
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("Tide-Diagnostics-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        try diagnosticsText(inputs).write(
            to: staging.appendingPathComponent("diagnostics.txt"), atomically: true, encoding: .utf8)
        try logText(logs).write(
            to: staging.appendingPathComponent("sync-log.txt"), atomically: true, encoding: .utf8)

        // DB スナップショット（一貫コピー）。失敗しても診断テキスト/ログは残す。
        if let db = env.database {
            try? await db.snapshot(to: staging.appendingPathComponent("db.sqlite"))
        }

        // 4) ステージングを zip 化（NSFileCoordinator の .forUploading は依存無しでディレクトリを zip 化する）
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
