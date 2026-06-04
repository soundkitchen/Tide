import SwiftUI

struct MenuBarContent: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()
            statusSection
            Divider()
            actions
        }
        .padding(12)
        .frame(width: 320)
        .task {
            await env.bootstrap()
            if !env.isSetupCompleted || env.bootstrapFailure != nil {
                openSetupWindow()
            }
        }
    }

    private func openSetupWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "setup")
    }

    private func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "settings")
    }

    private var header: some View {
        HStack {
            Image(systemName: "icloud.and.arrow.up")
                .font(.title2)
            Text("Tide")
                .font(.headline)
            Spacer()
        }
    }

    @ViewBuilder
    private func transfersSection(_ transfers: [TransferProgress]) -> some View {
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
                        Text(verbatim: (t.path as NSString).lastPathComponent)
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
    }

    @ViewBuilder
    private var statusSection: some View {
        if let engine = env.engine {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    statusDot(for: engine.status)
                    Text(statusLabel(engine.status))
                        .font(.subheadline)
                }
                if let last = engine.lastSyncedAt {
                    Text("Last sync: \(last.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let last = engine.lastRemoteCheckedAt {
                    Text("Last remote check: \(last.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Queue: \(engine.queueDepth)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !engine.activeTransfers.isEmpty {
                    transfersSection(engine.activeTransfers)
                }
                if !engine.recentErrors.isEmpty {
                    DisclosureGroup("Recent errors (\(engine.recentErrors.count))") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(engine.recentErrors.suffix(10).enumerated()), id: \.offset) { _, msg in
                                    Text(msg)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .frame(maxHeight: 120)
                    }
                    .font(.caption)
                }
            }
        } else if env.isSetupCompleted, env.bootstrapFailure == nil {
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
                    openSetupWindow()
                }
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let engine = env.engine {
                HStack {
                    switch engine.status {
                    case .paused:
                        Button("Resume") { engine.resume() }
                    default:
                        Button("Pause") { engine.pause() }
                    }
                    Button("Force scan") {
                        Task { await engine.triggerFullScan() }
                    }
                    Button("Pull from S3") {
                        Task { await engine.triggerRemotePull() }
                    }
                }
            }
            Button("Open Sync Folder") {
                openSyncFolder()
            }
            .disabled(env.config.syncRootPath == nil)
            Button("Settings…") {
                openSettingsWindow()
            }
            Divider()
            Button("Quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    private func statusDot(for status: SyncStatus) -> some View {
        let color: Color = {
            switch status {
            case .notConfigured: return .gray
            case .idle:          return .green
            case .syncing:       return .blue
            case .paused:        return .yellow
            case .error:         return .red
            }
        }()
        return Circle().fill(color).frame(width: 8, height: 8)
    }

    private func statusLabel(_ status: SyncStatus) -> String {
        switch status {
        case .notConfigured: return String(localized: "Not configured")
        case .idle:          return String(localized: "Idle")
        case .syncing(let p):
            if let f = p.currentFile { return String(localized: "Syncing… \(f)") }
            return String(localized: "Syncing…")
        case .paused:        return String(localized: "Paused")
        case .error(let m):  return String(localized: "Error: \(m)")
        }
    }

    private func openSyncFolder() {
        guard let path = env.config.syncRootPath, !path.isEmpty else { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
              isDir.boolValue else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }
}
