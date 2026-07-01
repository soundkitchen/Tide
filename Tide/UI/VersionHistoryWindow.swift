import TideCore
import SwiftUI

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
        // 削除一覧の軽量キャッシュ（#29 (b)）をオープン時に 1 回読み、Deleted タブを即表示できるようにする。
        .task { await model.loadDeletedCache(env: env) }
    }

    // MARK: - ファイル選択

    private var fileChooser: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // 1 本の欄が「同期一覧の絞り込み検索」と「任意パスの手入力」を兼ねる。
                TextField("Filter synced files or type a relative path", text: $model.pathInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { load() }
                Button("Load versions") { load() }
                    .disabled(model.pathInput.trimmingCharacters(in: .whitespaces).isEmpty || model.isLoading)
            }
            syncedFileList
        }
        .task { await model.loadSyncedPaths(env: env) }
    }

    /// 同期済みファイル（ローカル DB の `files`）のインライン一覧。`pathInput` で絞り込み、
    /// 行クリックでそのファイルの版を読み込む。一覧に無いパスは Enter で直接読み込める。
    @ViewBuilder
    private var syncedFileList: some View {
        let matches = model.filteredSyncedPaths
        if model.syncedPaths.isEmpty {
            Text("No synced files yet.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if matches.isEmpty {
            Text("No match — press Return to load this path.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            List(matches, id: \.self) { path in
                Button { selectSyncedPath(path) } label: {
                    HStack(spacing: 6) {
                        Text(verbatim: path)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if path == model.loadedPath {
                            Image(systemName: "checkmark")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(height: 150)
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
                // 一度でもフル列挙済み（キャッシュあり）なら再列挙＝Refresh、未列挙なら初回 Search。
                if model.deletedCacheUpdatedAt != nil {
                    Button("Refresh") { model.scanDeletedFiles(env: env) }
                } else {
                    Button("Search deleted files") { model.scanDeletedFiles(env: env) }
                }
            }
            if let updated = model.deletedCacheUpdatedAt, !model.isScanningDeleted {
                HStack(spacing: 4) {
                    Text("Last updated").font(.caption).foregroundStyle(.secondary)
                    Text(updated, style: .relative).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
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
                // キャッシュあり（列挙済み）で空＝本当に削除済みが無い。未列挙なら初回 Search を促す。
                if model.deletedCacheUpdatedAt != nil {
                    Text("No deleted files.").foregroundStyle(.secondary)
                } else {
                    Text("No deleted files found. Press Search to scan.")
                        .foregroundStyle(.secondary)
                }
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

    /// 同期一覧の行を選んだとき: 入力欄をそのパスにし（一覧も当該パスへ絞られる）、版を読み込む。
    private func selectSyncedPath(_ path: String) {
        model.pathInput = path
        load()
    }

    private static func dateString(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.tideTimestampLabel
    }
}
