import XCTest
import TideCore
@testable import Tide

/// パッケージ（#140）: ツリーがパッケージを 1 ノードに畳むこと、差分が種類の変化を分解すること、
/// 版の符号化が digest を通すことを固定する。判定は `PackageClassifier.extensions` で固定し、
/// この Mac の型情報には依存しない。
final class ManifestTreePackageTests: XCTestCase {
    private let packages = PackageClassifier.extensions(["key", "app", "framework"])

    private func entry(
        size: Int64 = 1, mtime: String = "2026-07-03T00:00:00Z", sha: String = "aa"
    ) -> ManifestFileEntry {
        ManifestFileEntry(
            size: size, mtime: mtime, sha256: sha,
            s3VersionId: nil, etag: "e", deviceId: "d", uploadedAt: mtime
        )
    }

    private func members(of node: ManifestTree.Node?) -> [String]? {
        guard case .package(_, let members, _, _)? = node else { return nil }
        return members.keys.sorted()
    }

    // MARK: - ツリー

    func testPackageFoldsMembersIntoOneNode() {
        let tree = ManifestTree(files: [
            "Talks/Deck.key/Index/Document.iwa": entry(),
            "Talks/Deck.key/Data/image.png": entry(sha: "bb"),
            "Talks/notes.txt": entry(),
        ], packages: packages)
        XCTAssertEqual(tree.children(of: "Talks")?.map(\.path), ["Talks/Deck.key", "Talks/notes.txt"])
        let deck = tree.node(at: "Talks/Deck.key")
        XCTAssertEqual(deck?.kind, .package)
        XCTAssertEqual(deck?.isDirectory, false)
        XCTAssertEqual(members(of: deck), ["Data/image.png", "Index/Document.iwa"])
        // 中身は子ノードとして出さない
        XCTAssertNil(tree.children(of: "Talks/Deck.key"))
        XCTAssertNil(tree.node(at: "Talks/Deck.key/Data"))
        XCTAssertNil(tree.node(at: "Talks/Deck.key/Data/image.png"))
    }

    func testSingleFileWithPackageExtensionStaysFile() {
        // 最後の要素は判定しない（単一ファイル形式の Keynote）
        let tree = ManifestTree(files: ["Deck.key": entry()], packages: packages)
        XCTAssertEqual(tree.node(at: "Deck.key")?.kind, .file)
    }

    func testNestedPackageFoldsOnlyOutermost() {
        let tree = ManifestTree(files: [
            "Tool.app/Contents/Frameworks/Lib.framework/Lib": entry(),
            "Tool.app/Contents/Info.plist": entry(),
        ], packages: packages)
        XCTAssertEqual(tree.node(at: "Tool.app")?.kind, .package)
        XCTAssertEqual(
            members(of: tree.node(at: "Tool.app")),
            ["Contents/Frameworks/Lib.framework/Lib", "Contents/Info.plist"])
        XCTAssertNil(tree.node(at: "Tool.app/Contents/Frameworks/Lib.framework"))
    }

    func testPackageWinsOverSameNamedFile() {
        // 壊れたマニフェスト（同名のファイルと中身が両方ある）は、中身を持つ側を残す（順序に依らない）
        for _ in 0..<20 {
            let tree = ManifestTree(files: [
                "Deck.key": entry(sha: "ff"),
                "Deck.key/Index/Document.iwa": entry(),
            ], packages: packages)
            XCTAssertEqual(tree.node(at: "Deck.key")?.kind, .package)
            XCTAssertEqual(tree.children(of: "")?.map(\.kind), [.package])
        }
    }

    func testPackageSizeAndMtimeComeFromMembers() {
        let tree = ManifestTree(files: [
            "d/Deck.key/a": entry(size: 3, mtime: "2026-07-01T00:00:00Z"),
            "d/Deck.key/b": entry(size: 4, mtime: "2026-07-05T00:00:00Z"),
        ], packages: packages)
        guard case .package(_, _, _, let mtime)? = tree.node(at: "d/Deck.key") else {
            return XCTFail("not a package")
        }
        XCTAssertEqual(mtime, ISO8601.parse("2026-07-05T00:00:00Z"))
        // 親ディレクトリの合成 mtime にもパッケージの中身が効く
        guard case .directory(_, let dirMtime)? = tree.node(at: "d") else { return XCTFail("not a dir") }
        XCTAssertEqual(dirMtime, ISO8601.parse("2026-07-05T00:00:00Z"))
    }

    func testFilePathsCountPackageOnce() {
        let tree = ManifestTree(files: [
            "Deck.key/a": entry(), "Deck.key/b": entry(), "x.txt": entry(),
        ], packages: packages)
        XCTAssertEqual(tree.filePaths.sorted(), ["Deck.key", "x.txt"])
    }

    func testEnclosingPackage() {
        let tree = ManifestTree(files: [
            "t/Deck.key/Data/a.png": entry(), "t/x.txt": entry(),
        ], packages: packages)
        XCTAssertEqual(tree.enclosingPackage(of: "t/Deck.key/Data/a.png")?.path, "t/Deck.key")
        XCTAssertEqual(tree.enclosingPackage(of: "t/Deck.key/New.txt")?.path, "t/Deck.key")
        XCTAssertNil(tree.enclosingPackage(of: "t/Deck.key"))
        XCTAssertNil(tree.enclosingPackage(of: "t/x.txt"))
        XCTAssertNil(tree.enclosingPackage(of: "nope/Deck.key/a"))
    }

    func testClassifierNoneKeepsDirectories() {
        let tree = ManifestTree(files: ["Deck.key/a": entry()], packages: .none)
        XCTAssertEqual(tree.node(at: "Deck.key")?.kind, .directory)
        XCTAssertEqual(tree.node(at: "Deck.key/a")?.kind, .file)
    }

    // MARK: - バッジ

    func testBadgeCountsPackageAsOneLeaf() {
        // 実体化セットにはパッケージ（`k:`）が 1 件で載る。フォルダのチェックもツリーの葉で数えるので、
        // 中身のパスではなくパッケージのパスが実体化していれば親フォルダにチェックが付く。
        let tree = ManifestTree(files: [
            "t/Deck.key/Index/Document.iwa": entry(), "t/Deck.key/Data/a.png": entry(),
            "t/x.txt": entry(),
        ], packages: packages)
        XCTAssertEqual(
            MaterializedBadge.checkedDirectories(
                filePaths: tree.filePaths, materialized: ["t/Deck.key", "t/x.txt"]),
            ["t"])
        XCTAssertEqual(
            MaterializedBadge.checkedDirectories(filePaths: tree.filePaths, materialized: ["t/x.txt"]),
            [])
        // パッケージの中にフォルダのチェックは作らない
        XCTAssertFalse(
            MaterializedBadge.checkedDirectories(
                filePaths: tree.filePaths, materialized: ["t/Deck.key"]
            ).contains("t/Deck.key/Index"))
    }

    // MARK: - digest

    func testDigestDependsOnPathsAndContentNotMtime() {
        let base = ["a": entry(sha: "11"), "b/c": entry(sha: "22")]
        let digest = ManifestTree.packageDigest(members: base)
        XCTAssertEqual(digest.count, 64)
        XCTAssertNotNil(FileProviderWritePolicy.baseSha(fromContentVersion: Data(digest.utf8)))
        // mtime だけの変化では変わらない
        XCTAssertEqual(digest, ManifestTree.packageDigest(members: [
            "a": entry(mtime: "2027-01-01T00:00:00Z", sha: "11"), "b/c": entry(sha: "22"),
        ]))
        // 内容・パス・件数の変化で変わる
        XCTAssertNotEqual(digest, ManifestTree.packageDigest(members: ["a": entry(sha: "11"), "b/c": entry(sha: "23")]))
        XCTAssertNotEqual(digest, ManifestTree.packageDigest(members: ["a": entry(sha: "11"), "b/d": entry(sha: "22")]))
        XCTAssertNotEqual(digest, ManifestTree.packageDigest(members: ["a": entry(sha: "11")]))
        // 区切りのずらしで衝突しない（"a" + "b/c" と "ab" + "/c" のような組み替え）
        XCTAssertNotEqual(
            ManifestTree.packageDigest(members: ["ab": entry(sha: "1")]),
            ManifestTree.packageDigest(members: ["a": entry(sha: "b1")]))
    }

    // MARK: - 版の符号化

    func testVersionEncodingUsesDigest() {
        let tree = ManifestTree(files: ["Deck.key/a": entry(sha: "11")], packages: packages)
        let node = tree.node(at: "Deck.key")!
        guard case .package(_, _, let digest, _) = node else { return XCTFail("not a package") }
        XCTAssertEqual(FileProviderWritePolicy.contentVersion(for: node), Data(digest.utf8))
        XCTAssertEqual(
            FileProviderWritePolicy.metadataVersion(for: node, materialized: true),
            Data((digest + "|m").utf8))
        // rebind 後でも metadataVersion から 3-way ベースを復元できる
        XCTAssertEqual(
            FileProviderWritePolicy.baseSha(
                contentVersion: Data("local-stamp".utf8),
                metadataVersion: FileProviderWritePolicy.metadataVersion(for: node, materialized: true)),
            digest)
    }

    // MARK: - 差分

    func testMemberChangeUpdatesPackageOnly() {
        let old = ManifestTree(files: ["t/Deck.key/a": entry(sha: "11")], packages: packages)
        let new = ManifestTree(files: ["t/Deck.key/a": entry(sha: "12")], packages: packages)
        let changes = ManifestTreeDiff.changes(from: old, to: new)
        XCTAssertEqual(changes.updated.map(\.path), ["t/Deck.key"])
        XCTAssertTrue(changes.deleted.isEmpty)
    }

    func testFileToPackageIsSplitIntoDeleteAndUpdate() {
        // Keynote の単一ファイル → パッケージへの保存し直し
        let old = ManifestTree(files: ["Deck.key": entry()], packages: packages)
        let new = ManifestTree(files: ["Deck.key/Index/Document.iwa": entry()], packages: packages)
        let changes = ManifestTreeDiff.changes(from: old, to: new)
        XCTAssertEqual(changes.updated.map(\.kind), [.package])
        XCTAssertEqual(changes.deleted.map(\.kind), [.file])
        XCTAssertEqual(changes.deleted.map(\.path), ["Deck.key"])
    }

    func testDirectoryToPackageDeletesOldDirectoryAndItsChildren() {
        // 型情報が変わって（アプリを入れた等）フォルダがパッケージになった
        let files = ["p/Deck.key/a": entry(), "p/Deck.key/sub/b": entry()]
        let old = ManifestTree(files: files, packages: .none)
        let new = ManifestTree(files: files, packages: packages)
        let changes = ManifestTreeDiff.changes(from: old, to: new)
        XCTAssertEqual(changes.updated.map(\.path), ["p/Deck.key"])
        XCTAssertEqual(changes.updated.map(\.kind), [.package])
        XCTAssertEqual(
            changes.deleted.map { "\($0.kind):\($0.path)" },
            ["directory:p/Deck.key", "file:p/Deck.key/a", "directory:p/Deck.key/sub", "file:p/Deck.key/sub/b"])
    }

    // MARK: - 本番の判定

    /// 本番の判定（`.system`）はその Mac の型情報で決まり、ツリーの既定（`.active`）はそれを使う。
    /// OS が宣言する型（`.app`）だけで確かめ、入っているアプリで変わる型（`.key` など）には頼らない。
    func testSystemClassifierUsesTypeInformation() {
        let system = PackageClassifier.system
        XCTAssertTrue(system.isPackage(name: "Tool.app"))
        XCTAssertTrue(system.isPackage(name: "Tool.APP"))
        XCTAssertTrue(system.isPackage(name: "Notes.rtfd"))
        // フレームワークは Finder でもフォルダとして見える
        XCTAssertFalse(system.isPackage(name: "Lib.framework"))
        // ファイルの型・宣言の無い拡張子（仮の型）・拡張子なし
        XCTAssertFalse(system.isPackage(name: "notes.txt"))
        XCTAssertFalse(system.isPackage(name: "paper.pdf"))
        XCTAssertFalse(system.isPackage(name: "repo.git"))
        XCTAssertFalse(system.isPackage(name: "Makefile"))
        let tree = ManifestTree(files: ["bin/Tool.app/Contents/Info.plist": entry()])
        XCTAssertEqual(members(of: tree.node(at: "bin/Tool.app")), ["Contents/Info.plist"])
    }
}
