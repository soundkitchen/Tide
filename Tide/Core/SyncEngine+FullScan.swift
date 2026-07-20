import TideCore
import Foundation
import GRDB

// MARK: - 単一走査フルスキャン（#64）
//
// `performFullScan` の走査本体。flat な `FileManager.enumerator` ではなく**ディレクトリ再帰下降**
// （明示スタックの反復 DFS）で走査し、各ディレクトリへ進入した時点でそのディレクトリの
// `.syncignore` を読んで層コンテキストへ加えてから配下ファイルを評価する（git モデル）。
// これにより「dir の `.syncignore` を配下ファイル評価より先に読む」が構造的に保証され、
// 起動時 / ローカル `.syncignore` 変更時に必要だった discovery 走査（`loadLayeredIgnore`）を
// scan へ畳み込める＝ツリー走査が 1 回になる。走査の副産物として全 `.syncignore` の層辞書
// （`LayeredSyncIgnore`）も組み上げ、呼び元（@MainActor）が scan 完了時に世代ガード付きで
// publish する。
//
// 旧 flat 実装との挙動差（意図的・`docs/08` 参照）:
// - 機密網 dir（`.aws` / `.ssh` …）は subtree ごと降りない（旧実装は降りて per-file フィルタ）。
//   `HardcodedIgnoreRules.shouldIgnore` はパスコンポーネント単位判定なので検出結果は同値で、
//   配下の stat だけが減る。
// - dir の子列挙に失敗したらスキャン全体を中断する（旧 enumerator は黙って skip）。配下の
//   追跡ファイルが foundPaths から欠落したまま削除検出に進むと S3 への誤 delete になるため、
//   欠落したまま続行するより安全側に倒す。
// - `.syncignore` が `maxFiles` 上限を超えても**走査は最後まで続ける**（層の追加だけ打ち切る）。
//   旧 discovery は走査ごと break したが、scan は削除検出の正しさのため全域走査が必須。
extension SyncEngine {

    /// 単一走査フルスキャンの結果（enqueue 件数 + 走査副産物の層状マッチャ）。
    struct SinglePassScanResult: Sendable {
        let newEnqueued: Int
        let deletedEnqueued: Int
        let mtimesRepaired: Int
        let ignoreMatcher: LayeredSyncIgnore
    }

    /// syncRoot 配下を 1 回だけ走査して、per-file 変更判定（`classifyLocalChange`）→ 2 段 enqueue
    /// （削除 → upload）と `.syncignore` 層辞書の構築を同時に行う。依存注入の nonisolated static で、
    /// テストから直接駆動できる（`FullScanSinglePassTests`）。
    ///
    /// セキュリティ不変条件（C1 / C2 / Issue #54）:
    /// - symlink（dir リンク含む）は絶対に追従しない。再帰下降では「スタックへ push しない」＝
    ///   構造的に降りない。旧 enumerator の `skipDescendants()` 誤用問題（Issue #54: 他の子の
    ///   走査に影響する API を symlink item で呼ぶと隣接 dir が欠落）はこの形では存在しない。
    /// - 機密網 dir に降りない・機密網ファイルを foundPaths に入れない（`HardcodedIgnoreRules` 最優先）。
    /// - per-file で `PathValidator.validateRelativePath`、`.syncignore` 読込は `readSyncignoreLayer`
    ///   の安全ゲート（`resolveSafely` + symlink 再確認 + 256KB 上限）を通す。
    /// - 除外ファイルは foundPaths に入れない（入れ漏れは S3 への誤 delete、入れ過ぎは削除検出漏れ）。
    nonisolated static func singlePassScan(
        root: URL, db: LocalDatabase, now: Double
    ) async throws -> SinglePassScanResult {
        let fm = FileManager.default

        var foundPaths: Set<String> = []
        // 走査中は upload 候補をバッファし、削除検出（enqueueScanDeletions）を先に enqueue して
        // から一括投入する（PR #53 レビュー #6）: 逐次 enqueue だとキューループが並行稼働している
        // ため「アプリ停止中の file→dir 置換」で子 upload が旧ファイルの delete より先に処理され、
        // #52 型の両立状態を一時的に S3 へ押し出し得る。
        var uploadCandidates: [String] = []
        var mtimesRepaired = 0

        // 走査副産物: 全 `.syncignore` の層辞書（scan 完了時 publish 用）。
        var allLayers: [String: SyncIgnoreMatcher] = [:]
        var layerCapWarned = false

        // 明示スタックの反復 DFS（深いツリーで Swift コールスタックを消費しない）。
        // ancestorLayers は「root からこの dir の**親**までに読んだ層」のみ（自 dir の層は進入時に
        // 読んで合成）。評価コンテキストが祖先層に限定されるため、旧実装のように全 dir を毎回
        // なめる評価にならない（docs/09 の「評価ホットパスの祖先辞書引き」解消）。
        var stack: [(url: URL, relative: String, ancestorLayers: [String: SyncIgnoreMatcher])] = [
            (root, "", [:])
        ]

        while let visit = stack.popLast() {
            // 子列挙の失敗（権限等）はスキャン全体を中断する（安全側・冒頭コメント参照）。
            let children = try fm.contentsOfDirectory(
                at: visit.url,
                includingPropertiesForKeys: [
                    .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                    .fileSizeKey, .contentModificationDateKey
                ],
                options: []  // hidden files（.git 等）を含める
            )

            // 1) 進入した dir の `.syncignore` を配下ファイル評価より先に読む（単一走査化の要）。
            //    読込の安全ゲートは readSyncignoreLayer 側（dir 実体/symlink/読込不能は nil = 層なし）。
            var layers = visit.ancestorLayers
            if children.contains(where: { $0.lastPathComponent == ".syncignore" }) {
                let rel = visit.relative.isEmpty ? ".syncignore" : visit.relative + "/.syncignore"
                if allLayers.count >= LayeredSyncIgnore.maxFiles {
                    if !layerCapWarned {
                        AppLogger.sync.error("Too many .syncignore files (>\(LayeredSyncIgnore.maxFiles)); ignoring the rest")
                        layerCapWarned = true
                    }
                } else if let matcher = readSyncignoreLayer(relativePath: rel, syncRoot: root) {
                    allLayers[visit.relative] = matcher
                    layers[visit.relative] = matcher
                }
            }
            let context = LayeredSyncIgnore(matchers: layers)

            // 2) 配下を層コンテキストで評価。dir は後段の push 候補へ、file は per-file パイプラインへ。
            var subdirs: [(url: URL, relative: String)] = []
            for child in children {
                let values = try child.resourceValues(forKeys: [
                    .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                    .fileSizeKey, .contentModificationDateKey
                ])
                // C2: シンボリックリンク（ディレクトリリンク含む）は絶対に追従しない＝push しない。
                if values.isSymbolicLink == true { continue }

                let relative = Self.relativePath(of: child, root: root)

                if values.isDirectory == true {
                    // 機密網 dir は subtree ごと降りない（冒頭コメント: per-file フィルタと検出同値）。
                    if HardcodedIgnoreRules.shouldIgnore(relativePath: relative) { continue }
                    subdirs.append((child, relative))
                    continue
                }
                guard values.isRegularFile == true else { continue }

                // —— per-file パイプライン（旧 flat 実装と同一・順序も維持） ——
                // ハードコード除外は DB を読む前に弾く（大きな除外ツリーでの無駄な DB 読みを避ける）
                if HardcodedIgnoreRules.shouldIgnore(relativePath: relative) { continue }
                // C1: 念のため相対パスを検証（root エスケープを防ぐ）
                do {
                    try PathValidator.validateRelativePath(relative)
                } catch {
                    continue
                }

                let size = Int64(values.fileSize ?? 0)
                let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0

                let existing = try await db.pool.read { db in
                    try FileRecord.fetchOne(db, key: relative)
                }

                // .syncignore のユーザパターン除外（既存追跡は触らない＝新規のみスキップ）。
                // スキップしたファイルは foundPaths に入れない（未追跡なので削除検出にも乗らない）。
                let tracked = (existing?.lastSyncedAt != nil)
                if IgnoreDecision.shouldSkip(relativePath: relative, isAlreadyTracked: tracked, matcher: context) {
                    continue
                }

                foundPaths.insert(relative)

                // 変更判定（preDecision → verifyHash → postHash → mtime CAS）は classifyLocalChange に
                // 集約（#30 / D1）。scan / event 両経路が同一ロジックを共有する。
                switch try await Self.classifyLocalChange(
                    existing: existing, fileURL: child, size: size, mtime: mtime,
                    relativePath: relative, db: db
                ) {
                case .skip, .mtimeCASNoop:
                    break
                case .mtimeRepaired:
                    mtimesRepaired += 1
                case .enqueue:
                    uploadCandidates.append(relative)
                }
            }

            for sub in subdirs {
                stack.append((sub.url, sub.relative, layers))
            }
        }

        // DB にあって実体走査で見つからなかった path を delete キューへ（集合差分 → enqueue の配線）。
        // upload より先に enqueue する（PR #53 レビュー #6・上記コメント参照）。
        let deletedEnqueued = try await Self.enqueueScanDeletions(db: db, foundPaths: foundPaths, now: now)

        // scan は onConflict: .ignore（リトライ中の attempts を巻き戻さない）。
        for relative in uploadCandidates {
            try await Self.enqueueUpload(db: db, path: relative, now: now, onConflict: .ignore)
        }

        return SinglePassScanResult(
            newEnqueued: uploadCandidates.count,
            deletedEnqueued: deletedEnqueued,
            mtimesRepaired: mtimesRepaired,
            ignoreMatcher: LayeredSyncIgnore(matchers: allLayers)
        )
    }

    /// `.syncignore` 1 枚の安全読込（走査とイベント patch の共通実装）。
    /// `PathValidator.resolveSafely` で root エスケープ拒否 + symlink 再確認 + 256KB 上限。
    /// 消滅 / 読込不能 / 超過は nil（= 層なし。全再構築でもその層は載らないので同値）。
    nonisolated static func readSyncignoreLayer(relativePath: String, syncRoot: URL) -> SyncIgnoreMatcher? {
        guard let safeURL = try? PathValidator.resolveSafely(relativePath: relativePath, syncRoot: syncRoot),
              !PathValidator.isSymbolicLink(at: safeURL),
              let data = try? Data(contentsOf: safeURL),
              data.count <= SyncIgnoreMatcher.maxBytes else { return nil }
        return SyncIgnoreMatcher.parse(String(decoding: data, as: UTF8.self))
    }
}
