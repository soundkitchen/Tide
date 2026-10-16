import XCTest
import TideCore
@testable import Tide

final class IgnoreDecisionTests: XCTestCase {
    /// ルート直下 `.syncignore` のみの層状マッチャを組む補助。
    private func root(_ text: String) -> LayeredSyncIgnore {
        LayeredSyncIgnore(root: SyncIgnoreMatcher.parse(text))
    }

    func testHardcodedAlwaysSkipped() {
        let m = LayeredSyncIgnore.empty
        // 追跡中でも未追跡でもハードコードは常にスキップ
        XCTAssertTrue(IgnoreDecision.shouldSkip(relativePath: ".env", isAlreadyTracked: false, matcher: m))
        XCTAssertTrue(IgnoreDecision.shouldSkip(relativePath: ".env", isAlreadyTracked: true, matcher: m))
        XCTAssertTrue(IgnoreDecision.shouldSkip(relativePath: "sub/server.pem", isAlreadyTracked: true, matcher: m))
    }

    func testNegationCannotReincludeHardcoded() {
        // !.env / !*.pem を書いてもハードコードが勝つ（機密は同期されない）
        let m = root("!.env\n!*.pem")
        XCTAssertTrue(IgnoreDecision.shouldSkip(relativePath: ".env", isAlreadyTracked: false, matcher: m))
        XCTAssertTrue(IgnoreDecision.shouldSkip(relativePath: "key.pem", isAlreadyTracked: false, matcher: m))
    }

    func testUserPatternSkipsOnlyUntracked() {
        let m = root("*.log")
        // 未追跡（新規）→ スキップ
        XCTAssertTrue(IgnoreDecision.shouldSkip(relativePath: "foo.log", isAlreadyTracked: false, matcher: m))
        // 既存追跡 → スキップしない（gitignore 純正・既存は触らない）
        XCTAssertFalse(IgnoreDecision.shouldSkip(relativePath: "foo.log", isAlreadyTracked: true, matcher: m))
    }

    func testSyncignoreItselfNeverSkipped() {
        // どんなユーザパターンでも .syncignore 自身は除外しない（設定が消えるのを防ぐ）
        let m = root("*\n.syncignore")
        XCTAssertFalse(IgnoreDecision.shouldSkip(relativePath: ".syncignore", isAlreadyTracked: false, matcher: m))
        XCTAssertFalse(IgnoreDecision.shouldSkip(relativePath: ".syncignore", isAlreadyTracked: true, matcher: m))
    }

    func testNestedSyncignoreNeverSkipped() {
        // ネストした .syncignore も自己保護（除外設定が同期から外れて消えるのを防ぐ）。
        // ルートの `*` で配下ファイルは除外されるが、各階層の .syncignore 自身は通す。
        let m = root("*")
        XCTAssertFalse(IgnoreDecision.shouldSkip(relativePath: "sub/.syncignore", isAlreadyTracked: false, matcher: m))
        XCTAssertFalse(IgnoreDecision.shouldSkip(relativePath: "a/b/c/.syncignore", isAlreadyTracked: false, matcher: m))
        // 名前末尾が .syncignore でも別ファイルなら自己保護しない（通常のユーザパターン判定に従う）。
        XCTAssertTrue(IgnoreDecision.shouldSkip(relativePath: "sub/my.syncignore", isAlreadyTracked: false, matcher: m))
    }

    func testNestedHardcodedBeatsNestedSyncignore() {
        // 機密網配下（.aws/）にある .syncignore はハードコードが最優先＝スキップ（同期しない）。
        let m = LayeredSyncIgnore.empty
        XCTAssertTrue(IgnoreDecision.shouldSkip(relativePath: ".aws/.syncignore", isAlreadyTracked: false, matcher: m))
    }

    func testNestedOverrideReincludesUntracked() {
        // ルートで *.log を除外、サブディレクトリの .syncignore で再包含 → 未追跡でもスキップしない。
        let m = LayeredSyncIgnore(matchers: [
            "": SyncIgnoreMatcher.parse("*.log"),
            "keep": SyncIgnoreMatcher.parse("!*.log")
        ])
        XCTAssertTrue(IgnoreDecision.shouldSkip(relativePath: "foo.log", isAlreadyTracked: false, matcher: m))
        XCTAssertFalse(IgnoreDecision.shouldSkip(relativePath: "keep/foo.log", isAlreadyTracked: false, matcher: m))
    }

    func testNonMatchingNotSkipped() {
        let m = root("*.log")
        XCTAssertFalse(IgnoreDecision.shouldSkip(relativePath: "report.pdf", isAlreadyTracked: false, matcher: m))
        XCTAssertFalse(IgnoreDecision.shouldSkip(relativePath: "report.pdf", isAlreadyTracked: true, matcher: m))
    }

    // MARK: - フォルダ単位除外（#120）

    private func excludesDir(
        _ path: String, tracked: Bool = false, _ m: LayeredSyncIgnore
    ) -> Bool {
        IgnoreDecision.shouldExcludeDirectory(
            relativePath: path, hasTrackedDescendants: tracked, matcher: m)
    }

    func testDirectoryPatternExcludesDirectoryAsWhole() {
        // 末尾 `/`（ディレクトリ限定）も素の名前も、フォルダそのものに一致すればフォルダ単位で除外
        let m = root("node_modules/\n.venv\n/dist/")
        XCTAssertTrue(excludesDir("node_modules", m))
        XCTAssertTrue(excludesDir("a/b/node_modules", m))
        XCTAssertTrue(excludesDir("proj/.venv", m))
        XCTAssertTrue(excludesDir("dist", m))
        // 先頭 `/` アンカーはルート直下のみ
        XCTAssertFalse(excludesDir("sub/dist", m))
        XCTAssertFalse(excludesDir("src", m))
    }

    func testFilePatternDoesNotExcludeDirectory() {
        // ファイル向けパターンはフォルダに一致しない = 従来どおり 1 ファイルずつ
        XCTAssertFalse(excludesDir("src", root("*.pyc")))
        // 配下の一部だけに一致するパターン（`build/*.o`）はフォルダ自身を除外しない
        XCTAssertFalse(excludesDir("build", root("build/*.o")))
        // `build/*` は配下すべてに一致する（照合は子孫にも及ぶ）ので、フォルダごと除外しても
        // 1 ファイルずつの判定と結果が変わらない
        XCTAssertTrue(excludesDir("build", root("build/*")))
        XCTAssertTrue(root("build/*").isIgnored("build/sub/deep.txt"))
    }

    func testTrackedDescendantsBlockDirectoryExclusion() {
        // 配下に追跡済みファイルがあれば、ユーザパターンでも機密網でもフォルダ単位で除外しない
        //（後始末の deleteItem が S3 から追跡済みファイルを消すため）
        XCTAssertFalse(excludesDir("node_modules", tracked: true, root("node_modules/")))
        XCTAssertFalse(excludesDir(".ssh", tracked: true, LayeredSyncIgnore.empty))
    }

    func testHardcodedDirectoryExcludedAsWhole() {
        // 機密網はユーザパターンが無くても、否定があってもフォルダ単位で除外
        XCTAssertTrue(excludesDir(".ssh", LayeredSyncIgnore.empty))
        XCTAssertTrue(excludesDir("sub/.aws", LayeredSyncIgnore.empty))
        XCTAssertTrue(excludesDir(".ssh", root("!.ssh/")))
    }

    func testNegationInEffectiveLayerFallsBackToPerFile() {
        // ルートに否定が 1 行でもあれば、その否定が配下に一致しなくても 1 ファイルずつへ戻す（保守側）
        XCTAssertFalse(excludesDir("node_modules", root("node_modules/\n!keep.txt")))
        // 祖先のネスト層の否定も同じ
        let nested = LayeredSyncIgnore(matchers: [
            "": SyncIgnoreMatcher.parse("node_modules/"),
            "app": SyncIgnoreMatcher.parse("!*.lock")
        ])
        XCTAssertFalse(excludesDir("app/node_modules", nested))
        // 祖先でない層（兄弟ディレクトリ）の否定は効かない
        XCTAssertTrue(excludesDir("web/node_modules", nested))
    }

    func testReincludedDirectoryNotExcluded() {
        // フォルダそのものが否定で再包含されている（否定があるので判定以前に戻る）
        XCTAssertFalse(excludesDir("build", root("build/\n!build/")))
    }

    // MARK: - 改名先のフォルダ単位除外（#124）

    private func excludesDirOnRename(_ path: String, _ m: LayeredSyncIgnore) -> Bool {
        IgnoreDecision.shouldExcludeDirectoryOnRename(relativePath: path, matcher: m)
    }

    func testRenameToDirectoryPatternExcludesAsWhole() {
        // `!` が無ければ従来どおりフォルダごと除外（追跡済みの有無は見ない = 改名で S3 から外す意図）
        XCTAssertTrue(excludesDirOnRename("build", root("build/")))
        XCTAssertTrue(excludesDirOnRename("a/node_modules", root("node_modules/")))
        XCTAssertFalse(excludesDirOnRename("src", root("build/")))
        XCTAssertFalse(excludesDirOnRename("src", root("*.pyc")))
    }

    func testRenameWithNegationIsAccepted() {
        // Issue #124 の例: 新規作成と同じく、`!` があればフォルダ単位で除外しない
        let m = root("build/\n!build/keep.txt")
        XCTAssertFalse(excludesDirOnRename("build", m))
        XCTAssertEqual(excludesDirOnRename("build", m), excludesDir("build", m))
        // 祖先のネスト層の否定も同じ・兄弟の層の否定は効かない
        let nested = LayeredSyncIgnore(matchers: [
            "": SyncIgnoreMatcher.parse("build/"),
            "app": SyncIgnoreMatcher.parse("!*.lock")
        ])
        XCTAssertFalse(excludesDirOnRename("app/build", nested))
        XCTAssertTrue(excludesDirOnRename("web/build", nested))
    }

    func testRenameToHardcodedDirectoryAlwaysExcluded() {
        // 機密網は否定があってもフォルダごと除外
        XCTAssertTrue(excludesDirOnRename(".ssh", LayeredSyncIgnore.empty))
        XCTAssertTrue(excludesDirOnRename("sub/.aws", root("!.aws/")))
    }
}
