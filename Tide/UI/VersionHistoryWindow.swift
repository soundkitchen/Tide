import SwiftUI
import AppKit

/// 過去バージョン参照 + 復元のウィンドウ（M4・サブ D）。
/// 削除済みファイル一覧（サブ E）は後でタブとして同居させる。
struct VersionHistoryWindow: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model = VersionHistoryModel()

    private enum HistoryTab: Hashable { case versions, deleted }
    @State private var tab: HistoryTab = .versions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Version History")
                .font(.title2).bold()

            if env.s3 == nil {
                Text("Run setup first to browse versions.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                Picker("", selection: $tab) {
                    Text("Versions").tag(HistoryTab.versions)
                    Text("Deleted files").tag(HistoryTab.deleted)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Divider()
                switch tab {
                case .versions:
                    fileChooser
                    versionsContent
                case .deleted:
                    deletedContent
                }
            }
        }
        .padding(16)
        .frame(minWidth: 540, minHeight: 460)
    }

    // MARK: - ファイル選択

    private var fileChooser: some View {
        HStack(spacing: 8) {
            TextField("Relative path (e.g. docs/note.txt)", text: $model.pathInput)
                .textFieldStyle(.roundedBorder)
                .onSubmit { load() }
            Button("Choose…") { chooseFile() }
            Button("Load versions") { load() }
                .disabled(model.pathInput.trimmingCharacters(in: .whitespaces).isEmpty || model.isLoading)
        }
    }

    // MARK: - 版一覧

    @ViewBuilder
    private var versionsContent: some View {
        if model.isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            if let note = model.restoreNote {
                Text(verbatim: note)
                    .font(.callout).foregroundStyle(.green).textSelection(.enabled)
            }
            if let err = model.errorMessage {
                Text(verbatim: err)
                    .font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .lineLimit(3)
            }
            if let path = model.loadedPath, !model.versions.isEmpty {
                HStack(spacing: 4) {
                    Text("Versions of")
                        .font(.headline).foregroundStyle(.secondary)
                    Text(verbatim: path).font(.headline)
                }
                versionList
            } else {
                Spacer()
            }
        }
    }

    private var versionList: some View {
        List(model.versions) { v in
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: Self.dateString(v.lastModified))
                        .font(.body).monospacedDigit()
                    HStack(spacing: 6) {
                        if v.isLatest { badge("Current", .blue) }
                        if v.isDeleteMarker { badge("Deleted", .red) }
                        if let size = v.size {
                            Text(verbatim: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                if v.isDeleteMarker {
                    Text("(deletion marker)")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Restore this version") {
                        Task { await model.restore(v, env: env) }
                    }
                    .disabled(model.isRestoring)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: .infinity)
    }

    private func badge(_ key: LocalizedStringKey, _ color: Color) -> some View {
        Text(key)
            .font(.caption2).bold()
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    // MARK: - 削除済みファイル（サブ E）

    @ViewBuilder
    private var deletedContent: some View {
        HStack(spacing: 8) {
            if model.isScanningDeleted {
                Button("Cancel") { model.cancelDeletedScan() }
                ProgressView().controlSize(.small)
                Text("Scanning…").foregroundStyle(.secondary)
                Text(verbatim: "(\(model.deletedScanned))").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Search deleted files") { model.scanDeletedFiles(env: env) }
            }
            Spacer()
        }
        if let note = model.restoreNote {
            Text(verbatim: note).font(.callout).foregroundStyle(.green).textSelection(.enabled)
        }
        if let err = model.errorMessage {
            Text(verbatim: err).font(.caption).foregroundStyle(.red).textSelection(.enabled).lineLimit(3)
        }
        if model.deletedFiles.isEmpty {
            if !model.isScanningDeleted {
                Text("No deleted files found. Press Search to scan.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        } else {
            deletedList
        }
    }

    private var deletedList: some View {
        List(model.deletedFiles) { h in
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: h.relativePath).font(.body)
                    if let v = h.latestRestorableVersion {
                        HStack(spacing: 6) {
                            Text(verbatim: Self.dateString(v.lastModified))
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            if let size = v.size {
                                Text(verbatim: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Spacer()
                Button("Restore") {
                    Task { await model.restoreDeleted(h, env: env) }
                }
                .disabled(model.isRestoring)
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - actions

    private func load() {
        Task { await model.loadVersions(for: model.pathInput, env: env) }
    }

    private func chooseFile() {
        guard let rootPath = env.config.syncRootPath, !rootPath.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // NSOpenPanel は実パスを返しがちなので、syncRoot 設定値が symlink を含む場合に備えて
        // 両辺とも symlink 解決してから比較する（さもないと正当な選択を弾く）。
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let rootStr = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let picked = url.standardizedFileURL.resolvingSymlinksInPath().path
        if picked.hasPrefix(rootStr) {
            model.pathInput = String(picked.dropFirst(rootStr.count))
            load()
        } else {
            model.errorMessage = String(localized: "Please choose a file inside the sync folder.")
        }
    }

    private static func dateString(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.tideTimestampLabel
    }
}
