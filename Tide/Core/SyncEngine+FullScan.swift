import TideCore
import Foundation
import GRDB

// MARK: - 単一走査フルスキャン（#64）
//
// `performFullScan` の走査本体。flat な `FileManager.enumerator` ではなく**ディレクトリ再帰下降**
// （明示スタックの反復 DFS）で走査し、各ディレクトリへ進入した時点でそのディレクトリの
// `.syncignore` を読んで層辞書へ加える（git モデル）。これにより「dir の `.syncignore` を配下
// ファイル評価より先に読む」が構造的に保証され、起動時 / ローカル `.syncignore` 変更時に必要
// だった discovery 走査（`loadLayeredIgnore`）を scan へ畳み込める＝ツリー走査が 1 回になる。
//
// PR #74 レビュー対応で **2 フェーズ構成**（レビュー中 3）:
// 1. `walkSyncTree` — FS 走査のみ（stat + 層辞書 + 対象ファイル収集・**DB 非接触**）。
//    完了時点で層辞書が完成するので、呼び元（`performFullScan`）は分類フェーズを待たずに
//    `ignoreMatcher` / `activeIgnorePatterns` へ publish できる（起動時に matcher が空のまま
//    event が評価される窓を、旧 discovery 走査相当の長さへ戻す）。
// 2. `classifyAndEnqueue` — 収集済みリストへ per-file の DB read / `classifyLocalChange` /
//    2 段 enqueue（削除 → upload）。除外評価は完成済みの層辞書で行う（`evaluate` は祖先層しか
//    見ないため、走査中の部分文脈で評価しても完成辞書で評価しても同値）。
//
// 旧 flat 実装との挙動差（意図的・`docs/08` 参照）:
// - 機密網 dir（`.aws` / `.ssh` …）は subtree ごと降りない（旧実装は降りて per-file フィルタ）。
//   `HardcodedIgnoreRules.shouldIgnore` はパスコンポーネント単位判定なので検出結果は同値で、
//   配下の stat だけが減る。
// - **syncRoot 自体**の列挙に失敗したらスキャン全体を中断する（旧 enumerator は黙って空を返し、
//   foundPaths 空のまま削除検出へ進んで全ファイル誤 delete し得た）。**配下 dir** の列挙失敗は
//   その subtree だけ skip し、削除検出のみ抑止する（`scanIncomplete`・レビュー高 2。旧実装の
//   「黙って skip → 配下の追跡ファイルが誤 delete」も「1 dir でスキャン全滅」も避ける）。
// - `.syncignore` が `maxFiles` 上限を超えても**走査は最後まで続ける**（層の追加だけ打ち切る）。
//   旧 discovery は走査ごと break したが、scan は削除検出の正しさのため全域走査が必須。
extension SyncEngine {

    /// 走査フェーズが収集する 1 ファイル分の情報（分類フェーズへの受け渡し・stat は走査時の 1 回のみ）。
    struct ScannedFile: Sendable {
        let url: URL
        let relative: String
        let size: Int64
        let mtime: Double
    }

    /// 走査フェーズ（`walkSyncTree`）の結果。
    struct TreeWalkResult: Sendable {
        /// 走査副産物: 全 `.syncignore` の層辞書（分類フェーズを待たず publish 可能）。
        let ignoreMatcher: LayeredSyncIgnore
        /// 収集した対象ファイル（symlink / 機密網 / 不正パス除去済み。ユーザパターン評価は分類フェーズ）。
        let files: [ScannedFile]
        /// 列挙に失敗して skip した配下 dir（相対パス）。非空なら削除検出を抑止する（レビュー高 2）。
        let unreadableDirs: [String]
        var scanIncomplete: Bool { !unreadableDirs.isEmpty }
    }

    /// 単一走査フルスキャン全体の結果（enqueue 件数 + 走査副産物）。
    struct SinglePassScanResult: Sendable {
        let newEnqueued: Int
        let deletedEnqueued: Int
        let mtimesRepaired: Int
        let ignoreMatcher: LayeredSyncIgnore
        let unreadableDirs: [String]
        var scanIncomplete: Bool { !unreadableDirs.isEmpty }
    }

    /// フェーズ 1: syncRoot 配下を 1 回だけ走査して、対象ファイルの収集と `.syncignore` 層辞書の
    /// 構築を行う（**DB 非接触**・同期関数）。テストから直接駆動できる（`FullScanSinglePassTests`）。
    ///
    /// セキュリティ不変条件（C1 / C2 / Issue #54）:
    /// - symlink（dir リンク含む）は絶対に追従しない。再帰下降では「スタックへ push しない」＝
    ///   構造的に降りない。旧 enumerator の `skipDescendants()` 誤用問題（Issue #54: 他の子の
    ///   走査に影響する API を symlink item で呼ぶと隣接 dir が欠落）はこの形では存在しない。
    /// - 機密網 dir に降りない・機密網ファイルを収集しない（`HardcodedIgnoreRules` 最優先）。
    /// - per-file で `PathValidator.validateRelativePath`、`.syncignore` 読込は `readSyncignoreLayer`
    ///   の安全ゲート（`resolveSafely` + lstat 相当の regular file 確認 + 256KB 上限）を通す。
    nonisolated static func walkSyncTree(root: URL) throws -> TreeWalkResult {
        let fm = FileManager.default

        var files: [ScannedFile] = []
        var allLayers: [String: SyncIgnoreMatcher] = [:]
        var unreadableDirs: [String] = []
        var layerCapWarned = false

        // 明示スタックの反復 DFS（深いツリーで Swift コールスタックを消費しない）。
        var stack: [(url: URL, relative: String)] = [(root, "")]

        while let visit = stack.popLast() {
            let children: [URL]
            do {
                children = try fm.contentsOfDirectory(
                    at: visit.url,
                    includingPropertiesForKeys: [
                        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                        .fileSizeKey, .contentModificationDateKey
                    ],
                    options: []  // hidden files（.git 等）を含める
                )
            } catch {
                // syncRoot 自体が列挙不能なら全体中断（空の foundPaths で削除検出に進むと
                // 全ファイル誤 delete）。配下 dir の失敗は subtree のみ skip し、削除検出は
                // 分類フェーズで丸ごと抑止する（upload / 層辞書 publish は継続・レビュー高 2）。
                if visit.relative.isEmpty { throw error }
                unreadableDirs.append(visit.relative)
                AppLogger.sync.error("Scan skipped unreadable directory: \(visit.relative, privacy: .private): \(String(describing: error), privacy: .private)")
                continue
            }

            // 進入した dir の `.syncignore` を層辞書へ（単一走査化の要）。読込の安全ゲートは
            // readSyncignoreLayer 側（symlink / FIFO 等の非 regular file / 読込不能 / 空は nil）。
            if children.contains(where: { $0.lastPathComponent == ".syncignore" }) {
                let rel = visit.relative.isEmpty ? ".syncignore" : visit.relative + "/.syncignore"
                if allLayers.count >= LayeredSyncIgnore.maxFiles {
                    if !layerCapWarned {
                        AppLogger.sync.error("Too many .syncignore files (>\(LayeredSyncIgnore.maxFiles)); ignoring the rest")
                        layerCapWarned = true
                    }
                } else if let matcher = readSyncignoreLayer(relativePath: rel, syncRoot: root) {
                    allLayers[visit.relative] = matcher
                }
            }

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
                    stack.append((child, relative))
                    continue
                }
                // FIFO / socket 等の非 regular file は対象外（旧実装と同じ）。
                guard values.isRegularFile == true else { continue }

                // ハードコード除外は収集前に弾く（分類フェーズの無駄な DB 読みを避ける）
                if HardcodedIgnoreRules.shouldIgnore(relativePath: relative) { continue }
                // C1: 念のため相対パスを検証（root エスケープを防ぐ）
                do {
                    try PathValidator.validateRelativePath(relative)
                } catch {
                    continue
                }

                files.append(ScannedFile(
                    url: child,
                    relative: relative,
                    size: Int64(values.fileSize ?? 0),
                    mtime: values.contentModificationDate?.timeIntervalSince1970 ?? 0
                ))
            }
        }

        return TreeWalkResult(
            ignoreMatcher: LayeredSyncIgnore(matchers: allLayers),
            files: files,
            unreadableDirs: unreadableDirs
        )
    }

    /// フェーズ 2: 収集済みファイルへ per-file 変更判定（`classifyLocalChange`）→ 2 段 enqueue
    /// （削除 → upload）。除外評価（`IgnoreDecision.shouldSkip`・未追跡のみ）と foundPaths 簿記も
    /// ここで行う（追跡有無の判定に DB read が要るため。ユーザパターンで除外したファイルは
    /// foundPaths に入れない＝未追跡なので削除検出にも乗らない）。
    nonisolated static func classifyAndEnqueue(
        walk: TreeWalkResult, db: LocalDatabase, now: Double
    ) async throws -> SinglePassScanResult {
        var foundPaths: Set<String> = []
        // 走査中は upload 候補をバッファし、削除検出（enqueueScanDeletions）を先に enqueue して
        // から一括投入する（PR #53 レビュー #6）: 逐次 enqueue だとキューループが並行稼働している
        // ため「アプリ停止中の file→dir 置換」で子 upload が旧ファイルの delete より先に処理され、
        // #52 型の両立状態を一時的に S3 へ押し出し得る。
        var uploadCandidates: [String] = []
        var mtimesRepaired = 0
        let matcher = walk.ignoreMatcher

        for file in walk.files {
            let existing = try await db.pool.read { db in
                try FileRecord.fetchOne(db, key: file.relative)
            }

            // .syncignore のユーザパターン除外（既存追跡は触らない＝新規のみスキップ）。
            let tracked = (existing?.lastSyncedAt != nil)
            if IgnoreDecision.shouldSkip(relativePath: file.relative, isAlreadyTracked: tracked, matcher: matcher) {
                continue
            }

            foundPaths.insert(file.relative)

            // 変更判定（preDecision → verifyHash → postHash → mtime CAS）は classifyLocalChange に
            // 集約（#30 / D1）。scan / event 両経路が同一ロジックを共有する。
            switch try await Self.classifyLocalChange(
                existing: existing, fileURL: file.url, size: file.size, mtime: file.mtime,
                relativePath: file.relative, db: db
            ) {
            case .skip, .mtimeCASNoop:
                break
            case .mtimeRepaired:
                mtimesRepaired += 1
            case .enqueue:
                uploadCandidates.append(file.relative)
            }
        }

        // DB にあって実体走査で見つからなかった path を delete キューへ（集合差分 → enqueue の配線）。
        // upload より先に enqueue する（PR #53 レビュー #6・上記コメント参照）。
        // 走査が不完全（列挙不能 dir を skip）なら削除検出を丸ごと抑止する（fail-safe・レビュー高 2:
        // skip した subtree の追跡ファイルが foundPaths から欠落したままだと S3 へ誤 delete になる）。
        let deletedEnqueued: Int
        if walk.scanIncomplete {
            deletedEnqueued = 0
            AppLogger.sync.warning("Deletion detection suppressed for this scan (unreadable directories)")
        } else {
            deletedEnqueued = try await Self.enqueueScanDeletions(db: db, foundPaths: foundPaths, now: now)
        }

        // scan は onConflict: .ignore（リトライ中の attempts を巻き戻さない）。
        for relative in uploadCandidates {
            try await Self.enqueueUpload(db: db, path: relative, now: now, onConflict: .ignore)
        }

        return SinglePassScanResult(
            newEnqueued: uploadCandidates.count,
            deletedEnqueued: deletedEnqueued,
            mtimesRepaired: mtimesRepaired,
            ignoreMatcher: walk.ignoreMatcher,
            unreadableDirs: walk.unreadableDirs
        )
    }

    /// 走査 + 分類の合成（直接駆動テスト用の便宜 API。`performFullScan` は層辞書 publish を
    /// 2 フェーズの間に挟むため、こちらではなく `walkSyncTree` → `classifyAndEnqueue` を個別に呼ぶ）。
    nonisolated static func singlePassScan(
        root: URL, db: LocalDatabase, now: Double
    ) async throws -> SinglePassScanResult {
        let walk = try walkSyncTree(root: root)
        return try await classifyAndEnqueue(walk: walk, db: db, now: now)
    }

    /// `.syncignore` 1 枚の安全読込（走査とイベント patch の共通実装）。
    /// `PathValidator.resolveSafely` で root エスケープ拒否 + **lstat 相当（`attributesOfItem` =
    /// symlink 非追従）の regular file 確認** + 256KB 上限。regular file 確認は symlink に加えて
    /// FIFO / socket も open 前に拒否する（FIFO を `Data(contentsOf:)` すると書き手待ちで永久
    /// ブロックし、フルスキャン / event 処理が再起動まで停止する。PR #74 レビュー高 1）。
    /// 消滅 / 非 regular / 読込不能 / 超過 / **空パターン**は nil（= 層なし。空を nil に正規化する
    /// ことで、patch 側の「新規層の追加」ガードが除去相当の patch を誤スキップしない。同 nit 5。
    /// 全再構築でも空層は `LayeredSyncIgnore.init` が落とすため意味論は同値）。
    nonisolated static func readSyncignoreLayer(relativePath: String, syncRoot: URL) -> SyncIgnoreMatcher? {
        guard let safeURL = try? PathValidator.resolveSafely(relativePath: relativePath, syncRoot: syncRoot),
              let attrs = try? FileManager.default.attributesOfItem(atPath: safeURL.path),
              (attrs[.type] as? FileAttributeType) == .typeRegular,
              let data = try? Data(contentsOf: safeURL),
              data.count <= SyncIgnoreMatcher.maxBytes else { return nil }
        let matcher = SyncIgnoreMatcher.parse(String(decoding: data, as: UTF8.self))
        return matcher.sourceLines.isEmpty ? nil : matcher
    }
}
