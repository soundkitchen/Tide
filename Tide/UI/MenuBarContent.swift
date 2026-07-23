import TideCore
import SwiftUI

struct MenuBarContent: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow

    /// 直近の同期済みファイル（upload/download/delete の sync_log 直読み・最大 3 件）。
    /// SyncEngine にメモリ状態を増やさず、ポップオーバー表示時と同期完了ごとに読み直す。
    @State private var recentActivity: [SyncLogRecord] = []

    /// fpOnly 表示用: FP ドメインの有効状態（nil = 未取得）。無効なら「何も同期されない」警告を出す。
    @State private var fileProviderEnabled: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let engine = env.engine {
                statusHeader(engine)
                syncInfoCard(engine)
                if !recentActivity.isEmpty {
                    recentActivityCard
                }
                if !engine.activeTransfers.isEmpty {
                    transfersCard(engine.activeTransfers)
                }
                if !engine.recentIssues.isEmpty {
                    issuesCard(engine)
                }
                Divider()
                primaryActions(engine)
            } else if let signaler = env.signaler {
                // FP-only 稼働モード（Track B-1）: engine == nil でも「Starting…」に落とさない
                // （PR #75 レビュー低 1）。同期の実体は FP 拡張なので、状態カードと Finder 導線だけ出す。
                fpOnlyHeader(signaler)
            } else {
                fallbackHeader
            }
            secondaryActions
        }
        .padding(12)
        .frame(width: 340)
        .task {
            await env.bootstrap()
            // 通知クリック → Sync Activity を開くアクションを登録（MenuBarLabel.onAppear の保険）。
            env.notifications.openActivity = {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "activity")
            }
            if !env.isSetupCompleted || env.bootstrapFailure != nil {
                activateAndOpen("setup")
            }
            // fpOnly 表示のときだけ FP 有効状態を取得（folderSync では余計な XPC を出さない）。
            if env.signaler != nil {
                fileProviderEnabled = await FileProviderController.isEnabled()
            }
        }
        // lastSyncedAt は upload 周回完了でしか前進しないため、pull 由来の download / 削除反映も
        // 拾えるよう lastRemoteCheckedAt と束ねて id にする（PR #17 レビュー Low-2）。
        .task(id: [env.engine?.lastSyncedAt, env.engine?.lastRemoteCheckedAt]) {
            await loadRecentActivity()
        }
    }

    // MARK: - window openers（LSUIElement: openWindow 前に必ず NSApp.activate）

    /// LSUIElement アプリはウィンドウを開く前にアプリを前面化しないと不可視のまま開く事故が起きるため、
    /// `openWindow(id:)` は必ずこの 1 経路を通す（NSApp.activate の前置を集約＝不変条件の単一管理）。
    private func activateAndOpen(_ id: String) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: id)
    }

    // MARK: - ステータスヘッダー

    private func statusHeader(_ engine: SyncEngine) -> some View {
        let presentation = MenuBarPresentation.headline(
            status: engine.status,
            queueDepth: engine.queueDepth,
            activeTransferCount: engine.activeTransfers.count
        )
        return HStack(spacing: 10) {
            Image(systemName: Self.symbol(for: presentation))
                .font(.title2)
                .foregroundStyle(Self.color(for: presentation))
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.headlineText(presentation))
                    .font(.headline)
                    .lineLimit(1)
                if case .syncing(let progress) = engine.status, let file = progress.currentFile {
                    Text(verbatim: file.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
        }
    }

    private static func headlineText(_ p: MenuBarPresentation) -> String {
        switch p {
        case .notConfigured:    return String(localized: "Not configured")
        case .allSynced:        return String(localized: "All synced")
        case .syncing(let pending):
            // 残作業の目安（queue と転送中の大きい方）。0 のときは件数を出さない。
            return pending > 0
                ? String(localized: "Syncing… (\(pending))")
                : String(localized: "Syncing…")
        case .paused:           return String(localized: "Paused")
        case .error(let s):     return String(localized: "Error: \(s)")
        }
    }

    private static func symbol(for p: MenuBarPresentation) -> String {
        switch p {
        case .notConfigured: return "questionmark.circle.fill"
        case .allSynced:     return "checkmark.circle.fill"
        case .syncing:       return "arrow.triangle.2.circlepath.circle.fill"
        case .paused:        return "pause.circle.fill"
        case .error:         return "exclamationmark.circle.fill"
        }
    }

    private static func color(for p: MenuBarPresentation) -> Color {
        switch p {
        case .notConfigured: return .gray
        case .allSynced:     return .green
        case .syncing:       return .blue
        case .paused:        return .yellow
        case .error:         return .red
        }
    }

    // MARK: - 同期情報カード

    private func syncInfoCard(_ engine: SyncEngine) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let last = engine.lastSyncedAt {
                Text("Last sync: \(last.formatted(date: .omitted, time: .standard))")
            }
            if let last = engine.lastRemoteCheckedAt {
                Text("Last remote check: \(last.formatted(date: .omitted, time: .standard))")
            }
            if engine.queueDepth > 0 {
                Text("\(engine.queueDepth) items queued")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .cardBackground()
    }

    // MARK: - 直近の同期ファイル

    private var recentActivityCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent activity")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(recentActivity, id: \.id) { entry in
                HStack(spacing: 4) {
                    // recentActivity は loadRecentActivity で upload/download/delete に絞っているため、
                    // "doc" フォールバックは rawValue 不正時のみ＝実質到達しない（フィルタ拡張時はここも追従）。
                    Image(systemName: SyncLogEventType(rawValue: entry.eventType)?.iconSymbol ?? "doc")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(verbatim: (entry.path ?? "").lastPathComponent)
                        .font(.caption2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(Date(timeIntervalSince1970: entry.timestamp), style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private func loadRecentActivity() async {
        guard let db = env.database else { return }
        let page = try? await db.fetchLogs(
            eventTypes: [.upload, .download, .delete], limit: 3
        )
        recentActivity = page?.records ?? []
    }

    // MARK: - 転送中カード

    private func transfersCard(_ transfers: [TransferProgress]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Transferring")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(transfers) { t in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Image(systemName: t.direction == .upload ? "arrow.up.circle" : "arrow.down.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(verbatim: t.path.lastPathComponent)
                            .font(.caption2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(verbatim: "\(Int(t.fraction * 100))%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    ProgressView(value: t.fraction)
                        .progressViewStyle(.linear)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    // MARK: - エラーカード（分類サマリ・F4）

    private func issuesCard(_ engine: SyncEngine) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Recent errors (\(engine.recentIssues.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { engine.clearIssues() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Details…") { activateAndOpen("activity") }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
            ForEach(MenuBarPresentation.groupIssues(engine.recentIssues), id: \.category) { group in
                issueGroupView(group)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private func issueGroupView(_ group: MenuBarPresentation.IssueGroup) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 3) {
                // グループ内は新しい順（groupIssues が整列済み）。表示は最新 5 件まで。
                ForEach(group.issues.prefix(5)) { issue in
                    issueRow(issue)
                }
            }
            .padding(.top, 2)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: group.category.symbolName)
                    .font(.caption2)
                    .foregroundStyle(.red)
                Text(group.category.localizedLabel)
                    .font(.caption)
                Spacer(minLength: 4)
                Text(verbatim: "\(group.issues.count)")
                    .font(.caption2).bold()
                    .padding(.horizontal, 5)
                    .background(Color.red.opacity(0.15), in: Capsule())
                    .foregroundStyle(.red)
            }
        }
        .font(.caption)
    }

    private func issueRow(_ issue: SyncIssue) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                if let path = issue.path {
                    Text(verbatim: path.lastPathComponent)
                        .font(.caption2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Text(issue.date, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let guidance = issue.category.localizedGuidance {
                Text(guidance)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .contextMenu {
            Button("Copy details") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(issue.rawDetail, forType: .string)
            }
        }
    }

    // MARK: - FP-only 稼働モード（Track B-1）

    @ViewBuilder
    private func fpOnlyHeader(_ signaler: RemoteChangeSignaler) -> some View {
        HStack(spacing: 10) {
            Image(systemName: fileProviderEnabled == false
                  ? "exclamationmark.circle.fill" : "externaldrive.fill.badge.icloud")
                .font(.title2)
                // nil = 有効状態の取得中（XPC 往復のサブ秒）。無効かもしれない間は緑を
                // 出さず中立色にする（PR #76 レビュー任意 3）。
                .foregroundStyle(fileProviderEnabled == false ? Color.red
                                 : fileProviderEnabled == true ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("File Provider Sync")
                    .font(.headline)
                    .lineLimit(1)
                Text("Files sync via the Tide location in Finder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        if fileProviderEnabled == false {
            Text("File Provider is not enabled — nothing is syncing. Enable it in Settings.")
                .font(.caption)
                .foregroundStyle(.red)
        }
        VStack(alignment: .leading, spacing: 3) {
            if let checked = signaler.lastCheckedAt {
                Text("Last remote check: \(checked.formatted(date: .omitted, time: .standard))")
            }
            if let signaled = signaler.lastSignaledAt {
                Text("Last change signaled: \(signaled.formatted(date: .omitted, time: .standard))")
            }
            if signaler.lastCheckFailed {
                Text("Remote check failed — will retry.")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .cardBackground()
        Divider()
    }

    // MARK: - 未起動時のフォールバック

    @ViewBuilder
    private var fallbackHeader: some View {
        HStack {
            Image(systemName: "icloud.and.arrow.up")
                .font(.title2)
            Text("Tide")
                .font(.headline)
            Spacer()
        }
        if env.isSetupCompleted, env.bootstrapFailure == nil {
            Text("Starting…")
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Not configured")
                    .foregroundStyle(.secondary)
                if let failure = env.bootstrapFailure {
                    Text(failure)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                Button("Run Setup…") {
                    activateAndOpen("setup")
                }
            }
        }
        Divider()
    }

    // MARK: - アクション

    private func primaryActions(_ engine: SyncEngine) -> some View {
        HStack(spacing: 6) {
            switch engine.status {
            case .paused:
                iconActionButton("Resume", systemImage: "play.fill") { engine.resume() }
            default:
                iconActionButton("Pause", systemImage: "pause.fill") { engine.pause() }
            }
            iconActionButton("Force scan", systemImage: "arrow.clockwise") {
                Task { await engine.triggerFullScan() }
            }
            // pull 中もボタンは enabled のまま（押下は pending 化され、現 pull 終了後に
            // もう 1 周走る = SyncEngine.triggerRemotePull の coalescing。PR #9 レビュー ④）。
            Button {
                Task { await engine.triggerRemotePull() }
            } label: {
                VStack(spacing: 3) {
                    if engine.isRemotePulling {
                        ProgressView()
                            .controlSize(.small)
                        Text("Pulling…")
                            .font(.caption2)
                    } else {
                        Image(systemName: "arrow.down.to.line")
                        Text("Pull from S3")
                            .font(.caption2)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.bordered)
        }
    }

    private func iconActionButton(
        _ titleKey: LocalizedStringKey, systemImage: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                Text(titleKey)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.bordered)
    }

    private var secondaryActions: some View {
        VStack(alignment: .leading, spacing: 2) {
            if env.signaler != nil {
                // fpOnly: 同期の実体は FP レプリカ。同期フォルダは凍結温存中なので導線を出さない
                // （開けると「同期されないフォルダ」を同期先と誤認しやすい）。FP 無効時は
                // userVisibleURL が nil = 無音の no-op になるため disable（「Open Sync Folder」の
                // syncRootPath == nil ガードと対称・PR #76 レビュー任意 2）。
                menuRow("Open Tide in Finder", systemImage: "folder") { openFileProviderFolder() }
                    .disabled(fileProviderEnabled == false)
            } else {
                menuRow("Open Sync Folder", systemImage: "folder") { openSyncFolder() }
                    .disabled(env.config.syncRootPath == nil)
            }
            if env.engine != nil {
                // Sync Activity は DB（sync_log）由来のため engine 稼働時のみ。
                menuRow("Sync Activity…", systemImage: "list.bullet.rectangle") { activateAndOpen("activity") }
            }
            if env.engine != nil || env.signaler != nil {
                // Version History は S3 直参照で列挙し、fpOnly でも S3 内復元（B-2）で復元できる。
                menuRow("Version History…", systemImage: "clock.arrow.circlepath") { activateAndOpen("versions") }
            }
            menuRow("Settings…", systemImage: "gearshape") { activateAndOpen("settings") }
            menuRow("About Tide", systemImage: "info.circle") { activateAndOpen("about") }
            Divider()
            menuRow("Quit", systemImage: "power") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    private func menuRow(
        _ titleKey: LocalizedStringKey, systemImage: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(titleKey, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 1)
    }

    private func openSyncFolder() {
        guard let path = env.config.syncRootPath, !path.isEmpty else { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
              isDir.boolValue else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    /// fpOnly: FP レプリカ（Finder の「場所 → Tide」）を開く。URL 取得は XPC 越しなので非同期。
    private func openFileProviderFolder() {
        Task {
            guard let url = await FileProviderController.userVisibleURL() else { return }
            // getUserVisibleURL の返す URL は security-scoped。scope を開始せずに NSWorkspace へ
            // 渡すと、sandbox 下では LS が「"Tide-Tide" を開くアクセス権がありません」で拒否する
            // （B-2 実機受け入れで発見・Apple Developer Forums thread 724398 と同事例）。
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            NSWorkspace.shared.open(url)
        }
    }
}
