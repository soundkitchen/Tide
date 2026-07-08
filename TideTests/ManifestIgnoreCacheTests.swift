import XCTest
import TideCore

/// `ManifestIgnoreCache`（M5 Phase 5-3・FP createItem の `.syncignore` 適用）の回帰固定。
/// - 世代アンカーキーのキャッシュ / single-flight 合流
/// - (path, sha) メモ化による世代跨ぎの再取得抑制
/// - pinned 版消失 → 最新版フォールバック → 両振りで層スキップ（除外しない安全側）
/// - sha 不一致 / fetch 失敗の伝播（createItem を一時エラーで再試行させる側）
/// - `LayeredSyncIgnore.maxFiles` 打ち切り（浅い層優先）
final class ManifestIgnoreCacheTests: XCTestCase {
    /// fetch 呼び出しを記録し、path → 応答を返すフェイク。
    private final class FetchRecorder: @unchecked Sendable {
        struct Call: Equatable {
            let path: String
            let versionId: String?
            let maxPrefixBytes: Int
        }

        private let lock = NSLock()
        private var _calls: [Call] = []
        /// (path, versionId なら "v" / nil なら "latest") → 応答。未登録は 404（nil）。
        private var responses: [String: ManifestIgnoreCache.FetchedFile] = [:]
        private var errors: [String: Error] = [:]

        var calls: [Call] {
            lock.lock()
            defer { lock.unlock() }
            return _calls
        }

        func respond(path: String, versionId: String?, sha: String, text: String) {
            lock.lock()
            defer { lock.unlock() }
            responses[key(path, versionId)] = .init(sha256: sha, prefix: Data(text.utf8))
            errors.removeValue(forKey: key(path, versionId))  // 回復シナリオ用（fail の解除）
        }

        func fail(path: String, versionId: String?, error: Error) {
            lock.lock()
            defer { lock.unlock() }
            errors[key(path, versionId)] = error
        }

        func record(_ call: Call) throws -> ManifestIgnoreCache.FetchedFile? {
            lock.lock()
            defer { lock.unlock() }
            _calls.append(call)
            if let error = errors[key(call.path, call.versionId)] { throw error }
            return responses[key(call.path, call.versionId)]
        }

        private func key(_ path: String, _ versionId: String?) -> String {
            "\(path)#\(versionId ?? "latest")"
        }
    }

    private struct FakeFetchError: Error {}

    private func makeCache(_ recorder: FetchRecorder) -> ManifestIgnoreCache {
        ManifestIgnoreCache { path, versionId, maxPrefixBytes in
            try recorder.record(.init(path: path, versionId: versionId, maxPrefixBytes: maxPrefixBytes))
        }
    }

    private func makeTree(_ files: [String: ManifestFileEntry]) -> ManifestTree {
        ManifestTree(files: files)
    }

    /// ルート + ネストの `.syncignore` から層状マッチャを組む（層キー: "" / dir 相対パス）。
    func testBuildsLayeredIgnoreFromManifest() async throws {
        let recorder = FetchRecorder()
        recorder.respond(path: ".syncignore", versionId: "v-root", sha: "root", text: "*.log\n")
        recorder.respond(path: "sub/.syncignore", versionId: "v-sub", sha: "sub", text: "*.tmp\n")
        let cache = makeCache(recorder)
        let tree = makeTree([
            ".syncignore": makeManifestEntry(sha: "root"),
            "sub/.syncignore": makeManifestEntry(sha: "sub"),
            "sub/data.bin": makeManifestEntry(sha: "data"),
        ])

        let layered = try await cache.layeredIgnore(tree: tree, anchor: "gen-1")

        XCTAssertEqual(layered.fileCount, 2)
        XCTAssertTrue(layered.isIgnored("a.log"))
        XCTAssertTrue(layered.isIgnored("sub/x.tmp"))
        XCTAssertTrue(layered.isIgnored("sub/x.log"))  // ルート層は配下にも効く
        XCTAssertFalse(layered.isIgnored("b.txt"))
        // 取得は versionId 固定 + 打ち切り上限つき
        XCTAssertTrue(recorder.calls.allSatisfy { $0.maxPrefixBytes == SyncIgnoreMatcher.maxBytes })
        XCTAssertEqual(
            Set(recorder.calls.map(\.path)), [".syncignore", "sub/.syncignore"]
        )
    }

    /// 同一アンカーの再要求は fetch ゼロ（世代キャッシュ）。
    func testSameAnchorServedFromCache() async throws {
        let recorder = FetchRecorder()
        recorder.respond(path: ".syncignore", versionId: "v-root", sha: "root", text: "*.log\n")
        let cache = makeCache(recorder)
        let tree = makeTree([".syncignore": makeManifestEntry(sha: "root")])

        _ = try await cache.layeredIgnore(tree: tree, anchor: "gen-1")
        let countAfterFirst = recorder.calls.count
        _ = try await cache.layeredIgnore(tree: tree, anchor: "gen-1")

        XCTAssertEqual(recorder.calls.count, countAfterFirst)
    }

    /// 世代が進んでも sha が変わらない `.syncignore` は再取得しない（メモ化）。
    /// 変わったファイルだけ取り直す。
    func testShaMemoAvoidsRefetchAcrossGenerations() async throws {
        let recorder = FetchRecorder()
        recorder.respond(path: ".syncignore", versionId: "v-root", sha: "root", text: "*.log\n")
        recorder.respond(path: "sub/.syncignore", versionId: "v-sub", sha: "sub", text: "*.tmp\n")
        let cache = makeCache(recorder)
        let tree1 = makeTree([
            ".syncignore": makeManifestEntry(sha: "root"),
            "sub/.syncignore": makeManifestEntry(sha: "sub"),
        ])
        _ = try await cache.layeredIgnore(tree: tree1, anchor: "gen-1")
        XCTAssertEqual(recorder.calls.count, 2)

        // 世代前進: root は不変、sub だけ内容が変わった
        recorder.respond(path: "sub/.syncignore", versionId: "v-sub2", sha: "sub2", text: "*.bak\n")
        let tree2 = makeTree([
            ".syncignore": makeManifestEntry(sha: "root"),
            "sub/.syncignore": makeManifestEntry(sha: "sub2"),
        ])
        let layered = try await cache.layeredIgnore(tree: tree2, anchor: "gen-2")

        XCTAssertEqual(recorder.calls.count, 3)  // 追加は sub の 1 回だけ
        XCTAssertEqual(recorder.calls.last?.path, "sub/.syncignore")
        XCTAssertTrue(layered.isIgnored("sub/x.bak"))
        XCTAssertFalse(layered.isIgnored("sub/x.tmp"))
    }

    /// pinned 版消失（404）→ 最新版フォールバック。両振りならその層をスキップ（除外しない）。
    func testPinnedMissingFallsBackToLatestThenSkips() async throws {
        let recorder = FetchRecorder()
        // pinned（v-root）は未登録 = 404。latest には新しい内容がある。
        recorder.respond(path: ".syncignore", versionId: nil, sha: "newer", text: "*.log\n")
        let cache = makeCache(recorder)
        let tree = makeTree([".syncignore": makeManifestEntry(sha: "root")])

        let layered = try await cache.layeredIgnore(tree: tree, anchor: "gen-1")
        XCTAssertTrue(layered.isIgnored("a.log"))

        // 両振り（pinned も latest も 404）→ 層スキップ = 何も除外しない
        let recorder2 = FetchRecorder()
        let cache2 = makeCache(recorder2)
        let layered2 = try await cache2.layeredIgnore(tree: tree, anchor: "gen-1")
        XCTAssertFalse(layered2.isIgnored("a.log"))
        XCTAssertEqual(layered2.fileCount, 0)
    }

    /// pinned 版の内容 sha がマニフェスト宣言と食い違う → throw（一時エラーとして再試行側へ）。
    func testPinnedShaMismatchThrows() async throws {
        let recorder = FetchRecorder()
        recorder.respond(path: ".syncignore", versionId: "v-root", sha: "unexpected", text: "*.log\n")
        let cache = makeCache(recorder)
        let tree = makeTree([".syncignore": makeManifestEntry(sha: "root")])

        do {
            _ = try await cache.layeredIgnore(tree: tree, anchor: "gen-1")
            XCTFail("expected contentMismatch")
        } catch let error as ManifestIgnoreCacheError {
            XCTAssertEqual(error, .contentMismatch(path: ".syncignore"))
        }
    }

    /// fetch のエラー（ネットワーク等）は伝播する（半端な層構成で除外判定しない）。
    /// 失敗後の再要求は再構築を試みる（エラーをキャッシュしない）。
    func testFetchErrorPropagatesAndDoesNotPoisonCache() async throws {
        let recorder = FetchRecorder()
        recorder.fail(path: ".syncignore", versionId: "v-root", error: FakeFetchError())
        let cache = makeCache(recorder)
        let tree = makeTree([".syncignore": makeManifestEntry(sha: "root")])

        do {
            _ = try await cache.layeredIgnore(tree: tree, anchor: "gen-1")
            XCTFail("expected FakeFetchError")
        } catch is FakeFetchError {
            // expected
        }

        // 回復後の再要求は成功する
        recorder.respond(path: ".syncignore", versionId: "v-root", sha: "root", text: "*.log\n")
        let layered = try await cache.layeredIgnore(tree: tree, anchor: "gen-1")
        XCTAssertTrue(layered.isIgnored("a.log"))
    }

    /// 手動開閉のゲート（異世代並行ビルドの完了順を決定的に制御する）。
    private actor AsyncGate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        var waiterCount: Int { waiters.count }

        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            opened = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    /// 異世代の並行ビルドで、遅れて完了した旧世代が新世代のキャッシュを巻き戻さない
    /// （PR #59 レビュー #1: 巻き戻ると次の新世代要求が 1 回無駄に再構築される）。
    func testLateFinishingOlderBuildDoesNotClobberNewerCache() async throws {
        let recorder = FetchRecorder()
        recorder.respond(path: ".syncignore", versionId: "v-a", sha: "a", text: "*.log\n")
        recorder.respond(path: ".syncignore", versionId: "v-b", sha: "b", text: "*.tmp\n")
        let gate = AsyncGate()
        let cache = ManifestIgnoreCache { path, versionId, maxPrefixBytes in
            if versionId == "v-a" { await gate.wait() }  // 旧世代のビルドだけ遅延させる
            return try recorder.record(
                .init(path: path, versionId: versionId, maxPrefixBytes: maxPrefixBytes))
        }
        let treeA = makeTree([".syncignore": makeManifestEntry(sha: "a")])
        let treeB = makeTree([".syncignore": makeManifestEntry(sha: "b")])

        async let older = cache.layeredIgnore(tree: treeA, anchor: "gen-a")
        // 旧世代ビルドがゲートに到達（= in-flight 登録済み）してから新世代を要求する
        while await gate.waiterCount == 0 { await Task.yield() }
        let newer = try await cache.layeredIgnore(tree: treeB, anchor: "gen-b")
        XCTAssertTrue(newer.isIgnored("x.tmp"))

        await gate.open()
        let olderResult = try await older
        XCTAssertTrue(olderResult.isIgnored("x.log"))  // 遅着側も自分の世代の正しい結果を得る

        // 新世代キャッシュが巻き戻っていない = 再要求が fetch ゼロで返る
        let countBefore = recorder.calls.count
        let again = try await cache.layeredIgnore(tree: treeB, anchor: "gen-b")
        XCTAssertTrue(again.isIgnored("x.tmp"))
        XCTAssertEqual(recorder.calls.count, countBefore)
    }

    /// 並行要求は single-flight で合流する（フォルダドラッグ = 並行 createItem の多重構築防止）。
    func testConcurrentRequestsCoalesce() async throws {
        let recorder = FetchRecorder()
        recorder.respond(path: ".syncignore", versionId: "v-root", sha: "root", text: "*.log\n")
        let cache = makeCache(recorder)
        let tree = makeTree([".syncignore": makeManifestEntry(sha: "root")])

        async let a = cache.layeredIgnore(tree: tree, anchor: "gen-1")
        async let b = cache.layeredIgnore(tree: tree, anchor: "gen-1")
        _ = try await (a, b)

        XCTAssertEqual(recorder.calls.count, 1)
    }

    /// `LayeredSyncIgnore.maxFiles` 超過分は深い層から打ち切る（除外しない = 同期する安全側）。
    func testMaxFilesCapDropsDeepestLayers() async throws {
        let recorder = FetchRecorder()
        var files: [String: ManifestFileEntry] = [
            ".syncignore": makeManifestEntry(sha: "root")
        ]
        recorder.respond(path: ".syncignore", versionId: "v-root", sha: "root", text: "*.log\n")
        // ルート 1 枚 + ネスト maxFiles 枚 = maxFiles + 1 枚（1 枚超過）。
        // 打ち切りは深さ優先（浅い層が生き残る）なので、最深層だけが落ちる。
        var deepDir = "d"
        for i in 0..<LayeredSyncIgnore.maxFiles {
            let path = "\(deepDir)/.syncignore"
            files[path] = makeManifestEntry(sha: "n\(i)")
            recorder.respond(path: path, versionId: "v-n\(i)", sha: "n\(i)", text: "*.tmp\n")
            deepDir += "/d"
        }
        let cache = makeCache(recorder)

        let layered = try await cache.layeredIgnore(tree: makeTree(files), anchor: "gen-1")

        XCTAssertEqual(layered.fileCount, LayeredSyncIgnore.maxFiles)
        XCTAssertTrue(layered.isIgnored("a.log"))  // ルート層は必ず生存
    }
}
