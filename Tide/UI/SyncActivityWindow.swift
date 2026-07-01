import TideCore
import SwiftUI
import AppKit

/// 同期アクティビティ（sync_log）の閲覧ウィンドウ（M4）。
/// 種別フィルタ + 新しい順リスト + 選択行の詳細ペイン（details のオンデマンド表示/コピー）。
/// DB 内の path / message / details は英語の生文字列なので必ず `Text(verbatim:)` で出す
/// （ローカライズ解決に流さない）。
struct SyncActivityWindow: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model = SyncActivityModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sync Activity")
                .font(.title2).bold()

            if let db = env.database {
                filterBar(db: db)
                Divider()
                content(db: db)
                if let entry = model.selectedEntry {
                    detailPane(entry)
                }
                Text("Logs older than 30 days are removed automatically.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Run setup first to view sync activity.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(16)
        .frame(minWidth: 620, minHeight: 460)
        .task {
            if let db = env.database {
                await model.reload(db: db)
            }
        }
    }

    // MARK: - フィルタ

    private func filterBar(db: LocalDatabase) -> some View {
        HStack(spacing: 6) {
            ForEach(SyncLogEventType.allCases, id: \.rawValue) { type in
                filterChip(type, db: db)
            }
            Spacer()
            if model.isLoading {
                ProgressView().controlSize(.small)
            }
            Button("Refresh") {
                Task { await model.reload(db: db) }
            }
        }
    }

    private func filterChip(_ type: SyncLogEventType, db: LocalDatabase) -> some View {
        let isOn = model.selectedTypes.contains(type)
        return Button {
            Task { await model.toggleFilter(type, db: db) }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: type.iconSymbol)
                Text(Self.label(for: type))
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(isOn ? Color.accentColor.opacity(0.15) : .clear, in: Capsule())
            .overlay(
                Capsule().strokeBorder(isOn ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.35))
            )
            .foregroundStyle(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 一覧

    @ViewBuilder
    private func content(db: LocalDatabase) -> some View {
        if let err = model.errorMessage {
            Text(verbatim: err)
                .font(.caption).foregroundStyle(.red).textSelection(.enabled)
                .lineLimit(3)
        }
        if model.entries.isEmpty {
            if !model.isLoading {
                // 全チップ off（仕様どおり 0 件）と「ログ自体が無い」を区別する（PR #17 レビュー nit-2）。
                if model.selectedTypes.isEmpty {
                    Text("No event types selected.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("No activity yet.")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        } else {
            // List(selection:) でキーボード上下 / VoiceOver の行選択を効かせる（PR #17 レビュー nit-3）。
            // fetch 済み行の id は常に非 nil（AUTOINCREMENT）なので `?? -1` は実質到達しない。
            List(selection: $model.selectedEntryId) {
                ForEach(model.entries, id: \.id) { entry in
                    row(entry)
                        .tag(entry.id ?? -1)
                }
                if model.hasMore {
                    HStack {
                        Spacer()
                        Button("Load more") {
                            Task { await model.loadMore(db: db) }
                        }
                        .disabled(model.isLoading)
                        Spacer()
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func row(_ entry: SyncLogRecord) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: SyncLogEventType(rawValue: entry.eventType)?.iconSymbol ?? "questionmark.circle")
                .foregroundStyle(SyncLogEventType(rawValue: entry.eventType)?.iconColor ?? .secondary)
                .frame(width: 16)
            Text(verbatim: Date(timeIntervalSince1970: entry.timestamp).tideTimestampLabel)
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                if let path = entry.path {
                    Text(verbatim: path)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(verbatim: entry.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
    }

    // MARK: - 詳細ペイン

    private func detailPane(_ entry: SyncLogRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: SyncLogEventType(rawValue: entry.eventType)?.iconSymbol ?? "questionmark.circle")
                    .foregroundStyle(SyncLogEventType(rawValue: entry.eventType)?.iconColor ?? .secondary)
                Text(verbatim: Date(timeIntervalSince1970: entry.timestamp).tideTimestampLabel)
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button("Copy details") {
                    let text = [entry.path, entry.message, entry.details]
                        .compactMap { $0 }
                        .joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if let path = entry.path {
                        Text(verbatim: path)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                    Text(verbatim: entry.message)
                        .font(.caption)
                        .textSelection(.enabled)
                    if let details = entry.details {
                        Text(verbatim: details)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 90)
        }
        .padding(10)
        .cardBackground()
    }

    // MARK: - 表示ヘルパ

    private static func label(for type: SyncLogEventType) -> String {
        switch type {
        case .upload:   return String(localized: "Uploads")
        case .download: return String(localized: "Downloads")
        case .delete:   return String(localized: "Deletions")
        case .conflict: return String(localized: "Conflicts")
        case .error:    return String(localized: "Errors")
        case .info:     return String(localized: "Info")
        }
    }

}
