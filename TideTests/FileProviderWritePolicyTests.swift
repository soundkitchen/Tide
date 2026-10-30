import XCTest
import TideCore

/// FP 書込経路の純粋判定（M5 Phase 5-2）。itemVersion → 3-way ベース sha の逆写像を固定する。
final class FileProviderWritePolicyTests: XCTestCase {
    func testBaseShaAcceptsLowercaseSha256Hex() {
        let sha = String(repeating: "0123456789abcdef", count: 4)  // 64 桁 hex 小文字
        XCTAssertEqual(
            FileProviderWritePolicy.baseSha(fromContentVersion: Data(sha.utf8)), sha
        )
    }

    func testBaseShaRejectsDirectorySentinel() {
        XCTAssertNil(FileProviderWritePolicy.baseSha(fromContentVersion: Data("dir".utf8)))
    }

    // MARK: - contentVersion 往復（PR #58 レビュー #8）

    /// file ノードは contentVersion(for:) → baseSha で往復する（符号化と復号の整合）。
    func testContentVersionRoundtripsForFile() {
        let sha = String(repeating: "0123456789abcdef", count: 4)
        let entry = ManifestFileEntry(
            size: 1, mtime: "2026-07-06T00:00:00Z", sha256: sha,
            s3VersionId: nil, etag: "e", deviceId: "d", uploadedAt: "2026-07-06T00:00:00Z"
        )
        let cv = FileProviderWritePolicy.contentVersion(for: .file(path: "a.txt", entry: entry))
        XCTAssertEqual(FileProviderWritePolicy.baseSha(fromContentVersion: cv), sha)
    }

    /// directory ノードの contentVersion は base sha を持たない（"dir" → nil）。
    func testContentVersionForDirectoryHasNoBaseSha() {
        let cv = FileProviderWritePolicy.contentVersion(for: .directory(path: "d", mtime: nil))
        XCTAssertNil(FileProviderWritePolicy.baseSha(fromContentVersion: cv))
    }

    func testBaseShaRejectsNonShaShapes() {
        XCTAssertNil(FileProviderWritePolicy.baseSha(fromContentVersion: nil))
        XCTAssertNil(FileProviderWritePolicy.baseSha(fromContentVersion: Data()))
        // 大文字 hex（発行元は小文字固定 = 規約外）
        let upper = String(repeating: "0123456789ABCDEF", count: 4)
        XCTAssertNil(FileProviderWritePolicy.baseSha(fromContentVersion: Data(upper.utf8)))
        // 長さ違い
        XCTAssertNil(FileProviderWritePolicy.baseSha(fromContentVersion: Data("abc123".utf8)))
        // 非 hex 文字
        let bad = String(repeating: "0123456789abcdeg", count: 4)
        XCTAssertNil(FileProviderWritePolicy.baseSha(fromContentVersion: Data(bad.utf8)))
        // 非 UTF-8
        XCTAssertNil(FileProviderWritePolicy.baseSha(fromContentVersion: Data([0xFF, 0xFE, 0x00])))
    }

    // MARK: - baseSha の metadataVersion フォールバック（rebind 対応・M5 Phase 5-4）

    /// contentVersion が sha 形でない（rebind item のローカル版スタンプ）とき、
    /// metadataVersion から復元する。両方 nil で初めてベース不明。
    func testBaseShaFallsBackToMetadataVersion() {
        let sha = String(repeating: "0123456789abcdef", count: 4)
        // contentVersion がローカルスタンプ（非 sha）でも metadataVersion から復元
        XCTAssertEqual(
            FileProviderWritePolicy.baseSha(
                contentVersion: Data("local-stamp-1".utf8), metadataVersion: Data(sha.utf8)),
            sha
        )
        // contentVersion が正常ならそちらを優先
        XCTAssertEqual(
            FileProviderWritePolicy.baseSha(
                contentVersion: Data(sha.utf8), metadataVersion: Data("dir".utf8)),
            sha
        )
        // 両方復元不能 = ベース不明
        XCTAssertNil(
            FileProviderWritePolicy.baseSha(
                contentVersion: Data("x".utf8), metadataVersion: nil)
        )
    }

    // MARK: - 実体化バッジの複合符号化（Issue #65）

    /// metadataVersion の複合形式（`<sha>|m`）は baseSha が剥がして復元する（rebind 互換の要）。
    func testBaseShaStripsMaterializedSuffix() {
        let sha = String(repeating: "0123456789abcdef", count: 4)
        XCTAssertEqual(
            FileProviderWritePolicy.baseSha(
                fromContentVersion: Data((sha + FileProviderWritePolicy.materializedSuffix).utf8)),
            sha
        )
        // metadataVersion フォールバック経由でも同様（rebind 後の実体化済み item の操作）
        XCTAssertEqual(
            FileProviderWritePolicy.baseSha(
                contentVersion: Data("local-stamp-1".utf8),
                metadataVersion: Data((sha + FileProviderWritePolicy.materializedSuffix).utf8)),
            sha
        )
    }

    /// 既知サフィックス以外の付加は従来どおり不正（受理面を広げない）。dir 形も引き続き nil。
    func testBaseShaRejectsUnknownSuffixShapes() {
        let sha = String(repeating: "0123456789abcdef", count: 4)
        XCTAssertNil(FileProviderWritePolicy.baseSha(fromContentVersion: Data((sha + "|x").utf8)))
        XCTAssertNil(FileProviderWritePolicy.baseSha(fromContentVersion: Data((sha + "m").utf8)))
        XCTAssertNil(FileProviderWritePolicy.baseSha(fromContentVersion: Data((sha + "|m|m").utf8)))
        // サフィックスだけ / dir 複合形
        XCTAssertNil(FileProviderWritePolicy.baseSha(fromContentVersion: Data("|m".utf8)))
        XCTAssertNil(FileProviderWritePolicy.baseSha(fromContentVersion: Data("dir|m".utf8)))
    }

    /// metadataVersion の符号化: file = sha（+ `|m`）/ dir = "dir-<mtime>"（+ `|m`）。
    /// file の非実体化形は旧形式（素の sha）と同一 = 後方互換（既存レプリカの baseVersion が
    /// そのまま復元できる）。
    func testMetadataVersionEncoding() {
        let sha = String(repeating: "0123456789abcdef", count: 4)
        let entry = ManifestFileEntry(
            size: 1, mtime: "2026-07-14T00:00:00Z", sha256: sha,
            s3VersionId: nil, etag: "e", deviceId: "d", uploadedAt: "2026-07-14T00:00:00Z"
        )
        let file = ManifestTree.Node.file(path: "a.txt", entry: entry)
        XCTAssertEqual(
            FileProviderWritePolicy.metadataVersion(for: file, materialized: false),
            Data(sha.utf8)
        )
        XCTAssertEqual(
            FileProviderWritePolicy.metadataVersion(for: file, materialized: true),
            Data((sha + "|m").utf8)
        )
        // 往復: 実体化形 metadataVersion → baseSha が sha を復元する
        XCTAssertEqual(
            FileProviderWritePolicy.baseSha(
                fromContentVersion: FileProviderWritePolicy.metadataVersion(
                    for: file, materialized: true)),
            sha
        )
        // dir: mtime なし / あり / 実体化形。いずれも baseSha は nil のまま（dir に内容ベースは無い）
        let bare = ManifestTree.Node.directory(path: "d", mtime: nil)
        XCTAssertEqual(
            FileProviderWritePolicy.metadataVersion(for: bare, materialized: false),
            Data("dir".utf8)
        )
        XCTAssertEqual(
            FileProviderWritePolicy.metadataVersion(for: bare, materialized: true),
            Data("dir|m".utf8)
        )
        let dated = ManifestTree.Node.directory(
            path: "d", mtime: ISO8601.parse("2026-07-14T00:00:00Z"))
        let datedMeta = FileProviderWritePolicy.metadataVersion(for: dated, materialized: true)
        XCTAssertEqual(String(data: datedMeta, encoding: .utf8), "dir-2026-07-14T00:00:00Z|m")
        XCTAssertNil(FileProviderWritePolicy.baseSha(fromContentVersion: datedMeta))
    }

    /// dir の metadataVersion から日時を取り出す（Issue #144）: 符号化との往復（実体化形も）と、
    /// 日時を持たない・dir でない・読めない版は nil。
    func testDirectoryMtimeRoundTripsThroughMetadataVersion() {
        let date = ISO8601.parse("2025-01-02T03:04:05Z")
        let dated = ManifestTree.Node.directory(path: "d", mtime: date)
        for materialized in [false, true] {
            XCTAssertEqual(
                FileProviderWritePolicy.directoryMtime(
                    fromMetadataVersion: FileProviderWritePolicy.metadataVersion(
                        for: dated, materialized: materialized)),
                date)
        }
        let bare = ManifestTree.Node.directory(path: "d", mtime: nil)
        XCTAssertNil(FileProviderWritePolicy.directoryMtime(
            fromMetadataVersion: FileProviderWritePolicy.metadataVersion(for: bare, materialized: false)))
        let sha = String(repeating: "0123456789abcdef", count: 4)
        XCTAssertNil(FileProviderWritePolicy.directoryMtime(fromMetadataVersion: Data(sha.utf8)))
        XCTAssertNil(FileProviderWritePolicy.directoryMtime(fromMetadataVersion: Data("dir-garbage".utf8)))
        XCTAssertNil(FileProviderWritePolicy.directoryMtime(fromMetadataVersion: Data([0xff, 0xfe])))
        XCTAssertNil(FileProviderWritePolicy.directoryMtime(fromMetadataVersion: nil))
    }

    /// 仮想フォルダを返すときの日時の優先順位（Issue #144・PR #154 レビュー指摘 1・2）:
    /// 日時が変わったなら item → そうでなければ版 → 版にも無ければ item。
    func testVirtualDirectoryMtimePrefersChangedItemDateThenBaseVersion() {
        let itemDate = ISO8601.parse("2026-10-31T00:00:00Z")
        let baseDate = ISO8601.parse("2025-01-02T03:04:05Z")
        let base = FileProviderWritePolicy.metadataVersion(
            for: .directory(path: "d", mtime: baseDate), materialized: false)
        let bare = Data("dir".utf8)
        // 日時の変更（touch）: item の日時
        XCTAssertEqual(FileProviderWritePolicy.virtualDirectoryMtime(
            dateChanged: true, itemDate: itemDate, baseMetadataVersion: base), itemDate)
        // 日時が変わったのに item に無い: 版で補う
        XCTAssertEqual(FileProviderWritePolicy.virtualDirectoryMtime(
            dateChanged: true, itemDate: nil, baseMetadataVersion: base), baseDate)
        // 改名・タグだけの変更: item に何が入っていても版を優先（item の値は保証されない）
        XCTAssertEqual(FileProviderWritePolicy.virtualDirectoryMtime(
            dateChanged: false, itemDate: Date(timeIntervalSince1970: 0), baseMetadataVersion: base),
            baseDate)
        XCTAssertEqual(FileProviderWritePolicy.virtualDirectoryMtime(
            dateChanged: false, itemDate: nil, baseMetadataVersion: base), baseDate)
        // 版に日時が無い: item の日時（無ければ nil）
        XCTAssertEqual(FileProviderWritePolicy.virtualDirectoryMtime(
            dateChanged: false, itemDate: itemDate, baseMetadataVersion: bare), itemDate)
        XCTAssertNil(FileProviderWritePolicy.virtualDirectoryMtime(
            dateChanged: false, itemDate: nil, baseMetadataVersion: nil))
    }

    // MARK: - childPath（createItem のパス合成・M5 Phase 5-3）

    func testChildPathJoinsParentAndFilename() {
        XCTAssertEqual(FileProviderWritePolicy.childPath(parentPath: "", filename: "a.txt"), "a.txt")
        XCTAssertEqual(
            FileProviderWritePolicy.childPath(parentPath: "docs/sub", filename: "a.txt"),
            "docs/sub/a.txt"
        )
        // dotfile も通常のファイル名（除外判定は呼び出し側の IgnoreDecision が担う）
        XCTAssertEqual(
            FileProviderWritePolicy.childPath(parentPath: "", filename: ".syncignore"), ".syncignore"
        )
    }

    /// filename 起因の構造破壊（空 / "." / ".." / ネスト注入 / NUL）は合成不能 = nil。
    func testChildPathRejectsStructuralBreakage() {
        XCTAssertNil(FileProviderWritePolicy.childPath(parentPath: "docs", filename: ""))
        XCTAssertNil(FileProviderWritePolicy.childPath(parentPath: "docs", filename: "."))
        XCTAssertNil(FileProviderWritePolicy.childPath(parentPath: "docs", filename: ".."))
        XCTAssertNil(FileProviderWritePolicy.childPath(parentPath: "docs", filename: "a/b.txt"))
        XCTAssertNil(FileProviderWritePolicy.childPath(parentPath: "docs", filename: "/a.txt"))
        XCTAssertNil(FileProviderWritePolicy.childPath(parentPath: "docs", filename: "a\0.txt"))
        // `/` の直後に結合文字を付けて書記素単位の判定から隠したネスト注入（#137）
        XCTAssertNil(FileProviderWritePolicy.childPath(parentPath: "docs", filename: "a/\u{301}b.txt"))
    }

    // MARK: - 通知に出す表示用のパス（Issue #147）

    /// 親と名前をつなぐだけで検証しない（同期できない名前もそのまま組み立てる）。
    func testDisplayPathJoinsWithoutValidation() {
        XCTAssertEqual(FileProviderWritePolicy.displayPath(parentPath: "", filename: "a\\b.txt"), "a\\b.txt")
        XCTAssertEqual(FileProviderWritePolicy.displayPath(parentPath: "docs/sub", filename: "x.pem"), "docs/sub/x.pem")
    }

    // MARK: - 版スタンプ自動治癒の対象選定（Issue #93）

    /// 実体化済み（旧パス掲載）のファイルだけが治癒対象。dataless は症状が可視化されず、
    /// 次の materialize（fetchContents）で自然に再刻印されるため撃たない（無駄撃ち防止）。
    func testMoveRestampTargetsGatesOnMaterialized() {
        let targets = FileProviderWritePolicy.moveRestampTargets(
            moves: [
                (from: "docs/a.txt", to: "docs/b.txt"),
                (from: "docs/dataless.txt", to: "docs/dataless2.txt"),
            ],
            materialized: ["docs/a.txt"]
        )
        XCTAssertEqual(targets, ["docs/b.txt"])
    }

    /// 観測タイミングにより実体化集合が新パス側（rebind / renameSubtree 後）で見える場合も
    /// 治癒対象に拾う（from / to の両建てゲート）。
    func testMoveRestampTargetsAcceptsNewPathMembership() {
        let targets = FileProviderWritePolicy.moveRestampTargets(
            moves: [(from: "old/a.txt", to: "new/a.txt")],
            materialized: ["new/a.txt"]
        )
        XCTAssertEqual(targets, ["new/a.txt"])
    }

    /// 実体化ファイルなし（dataless のみ / 空集合）は治癒対象なし = 無駄撃ちしない。
    func testMoveRestampTargetsEmptyWhenNothingMaterialized() {
        XCTAssertTrue(
            FileProviderWritePolicy.moveRestampTargets(
                moves: [(from: "a", to: "b")], materialized: []
            ).isEmpty
        )
        XCTAssertTrue(
            FileProviderWritePolicy.moveRestampTargets(moves: [], materialized: ["a"]).isEmpty
        )
    }

    /// dir move（複数ファイル）は入力順を保持して返す（ログ・リトライの追跡性）。
    func testMoveRestampTargetsPreservesOrder() {
        let targets = FileProviderWritePolicy.moveRestampTargets(
            moves: [
                (from: "d/1.txt", to: "e/1.txt"),
                (from: "d/2.txt", to: "e/2.txt"),
                (from: "d/3.txt", to: "e/3.txt"),
            ],
            materialized: ["d/3.txt", "d/1.txt"]
        )
        XCTAssertEqual(targets, ["e/1.txt", "e/3.txt"])
    }

    // MARK: - フォルダの deleteItem（#120 レビュー B1）

    func testDirectoryDeleteWithoutTrackedFilesIsLocalOnly() {
        // 追跡ゼロ（仮想フォルダ）は再帰の有無に関わらず S3 非接触
        XCTAssertEqual(FileProviderWritePolicy.directoryDeletePlan(
            trackedCount: 0, hasExclusionHold: false, recursive: true), .localOnly)
        XCTAssertEqual(FileProviderWritePolicy.directoryDeletePlan(
            trackedCount: 0, hasExclusionHold: false, recursive: false), .localOnly)
    }

    func testDirectoryDeleteWithTrackedFilesFollowsRecursiveFlag() {
        XCTAssertEqual(FileProviderWritePolicy.directoryDeletePlan(
            trackedCount: 3, hasExclusionHold: false, recursive: true), .deleteRemote)
        XCTAssertEqual(FileProviderWritePolicy.directoryDeletePlan(
            trackedCount: 3, hasExclusionHold: false, recursive: false), .notEmpty)
    }

    func testExclusionHoldKeepsTrackedFilesOnS3() {
        // 除外の予約がある後始末は、判定後に追跡済みファイルが現れていても S3 に触れない
        XCTAssertEqual(FileProviderWritePolicy.directoryDeletePlan(
            trackedCount: 3, hasExclusionHold: true, recursive: true), .localOnly)
        XCTAssertEqual(FileProviderWritePolicy.directoryDeletePlan(
            trackedCount: 0, hasExclusionHold: true, recursive: true), .localOnly)
    }

    func testPathAndAncestors() {
        XCTAssertEqual(
            FileProviderWritePolicy.pathAndAncestors("a/node_modules/pkg"),
            ["a/node_modules/pkg", "a/node_modules", "a"])
        XCTAssertEqual(FileProviderWritePolicy.pathAndAncestors("top"), ["top"])
        XCTAssertEqual(FileProviderWritePolicy.pathAndAncestors(""), [])
    }

    // MARK: - rename のコピー元の切り替え（#130）

    /// 宣言版が失効していても、最新版の ETag とサイズが一致すれば（= 中身が同じ）最新版を使う。
    /// 一致しない・最新版の versionId が無い・宣言版と同じ版なら切り替えない。
    func testCopySourceFallbackVersion() {
        let entry = makeManifestEntry(sha: "aaa", size: 550)  // versionId = "v-aaa", etag = "obj-etag-aaa"
        func fallback(_ etag: String, _ version: String?, _ size: Int64?) -> String? {
            FileProviderWritePolicy.copySourceFallbackVersion(
                entry: entry, latestEtag: etag, latestVersionId: version, latestSize: size)
        }
        XCTAssertEqual(fallback("obj-etag-aaa", "v-latest", 550), "v-latest")
        // 中身が違う（ETag 不一致）
        XCTAssertNil(fallback("obj-etag-bbb", "v-latest", 550))
        // サイズ不一致・サイズ不明
        XCTAssertNil(fallback("obj-etag-aaa", "v-latest", 551))
        XCTAssertNil(fallback("obj-etag-aaa", "v-latest", nil))
        // 最新版の versionId が無い（それを使うと版を固定できない）
        XCTAssertNil(fallback("obj-etag-aaa", nil, 550))
        // 最新版が宣言版そのもの（切り替えにならない）
        XCTAssertNil(fallback("obj-etag-aaa", "v-aaa", 550))
        // ETag が空
        var noEtag = entry
        noEtag.etag = ""
        XCTAssertNil(FileProviderWritePolicy.copySourceFallbackVersion(
            entry: noEtag, latestEtag: "", latestVersionId: "v-latest", latestSize: 550))
    }
}
