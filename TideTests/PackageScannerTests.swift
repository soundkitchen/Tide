import Darwin
import XCTest
import TideCore

/// パッケージの書込（#140）の TideCore 側: ローカルの中身の走査（`PackageScanner`）、書込の判定
/// （`FileProviderWritePolicy.packageWriteDecision`）、フォルダの削除・移動が使うツリーの一覧。
final class PackageScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PackageScannerTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Deck.key", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private func write(_ relative: String, _ text: String = "x") throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func scan(limit: Int = PackageScanner.memberLimit) throws -> PackageScanner.Result {
        try PackageScanner.scan(root: root, packagePath: "Talks/Deck.key", limit: limit)
    }

    private func memberPaths(_ result: PackageScanner.Result) -> [String]? {
        guard case .members(let members) = result else { return nil }
        return members.map(\.relativePath)
    }

    // MARK: - 走査

    func testCollectsNestedFilesSorted() throws {
        try write("Index/Document.iwa", "doc")
        try write("Data/image.png", "png!")
        try write("Metadata/Properties.plist")
        let result = try scan()
        XCTAssertEqual(memberPaths(result), ["Data/image.png", "Index/Document.iwa", "Metadata/Properties.plist"])
        guard case .members(let members) = result else { return XCTFail() }
        XCTAssertEqual(members.first?.size, 4)
        XCTAssertNotNil(members.first?.modified)
    }

    func testSkipsJunkAndSensitiveNamesSilently() throws {
        try write("Index/Document.iwa")
        try write(".DS_Store")
        try write("Data/._image.png")
        try write(".ssh/id_rsa")       // 機密網のフォルダは配下ごと
        try write("secret.pem")
        XCTAssertEqual(memberPaths(try scan()), ["Index/Document.iwa"])
    }

    func testIncludesHiddenFilesThatAreNotJunk() throws {
        try write(".hidden-config-of-app")
        XCTAssertEqual(memberPaths(try scan()), [".hidden-config-of-app"])
    }

    func testEmptyPackageHasNoMembers() throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        XCTAssertEqual(memberPaths(try scan()), [])
    }

    func testDescendsIntoNestedPackages() throws {
        try write("Contents/Frameworks/Lib.framework/Lib")
        XCTAssertEqual(memberPaths(try scan()), ["Contents/Frameworks/Lib.framework/Lib"])
    }

    // MARK: - 丸ごと除外

    func testSymlinkExcludesWholePackage() throws {
        try write("Index/Document.iwa")
        try write("Data/image.png")
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Data/link"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        XCTAssertEqual(try scan(), .excluded(.symbolicLink(relativePath: "Data/link")))
    }

    func testDirectorySymlinkIsNotFollowed() throws {
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("outside"), withDestinationURL: URL(fileURLWithPath: "/usr"))
        XCTAssertEqual(try scan(), .excluded(.symbolicLink(relativePath: "outside")))
    }

    func testFifoExcludesWholePackage() throws {
        let fifo = root.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertEqual(try scan(), .excluded(.unsupportedItem(relativePath: "pipe")))
    }

    func testUnsyncableNameExcludesWholePackage() throws {
        try write("Data/a\\b.png")
        XCTAssertEqual(try scan(), .excluded(.unsyncableName(relativePath: "Data/a\\b.png")))
    }

    func testTooManyFilesExcludesWholePackage() throws {
        for i in 0..<4 { try write("f\(i)") }
        XCTAssertEqual(memberPaths(try scan(limit: 4))?.count, 4)
        try write("f4")
        XCTAssertEqual(try scan(limit: 4), .excluded(.tooManyFiles(limit: 4)))
    }

    func testRootSymlinkIsRejected() throws {
        let link = root.deletingLastPathComponent().appendingPathComponent("Link.key")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertThrowsError(try PackageScanner.scan(root: link, packagePath: "Link.key"))
    }

    // MARK: - 書込の判定

    private func entry(sha: String) -> ManifestFileEntry {
        ManifestFileEntry(
            size: 1, mtime: "2026-10-30T00:00:00Z", sha256: sha,
            s3VersionId: "v", etag: "e", deviceId: "d", uploadedAt: "2026-10-30T00:00:00Z")
    }

    func testWriteDecision() {
        let members = ["a": entry(sha: "1"), "b": entry(sha: "2")]
        let remote = ManifestTree.packageNode(path: "Deck.key", members: members)
        let remoteDigest = ManifestTree.packageDigest(members: members)
        let localDigest = ManifestTree.packageDigest(shas: ["a": "1", "b": "3"])
        typealias P = FileProviderWritePolicy

        // 新規作成（リモートに無い）・ベースつきでリモートが消えていた = 書く
        XCTAssertEqual(P.packageWriteDecision(localDigest: localDigest, base: nil, remote: nil), .write(remoteMembers: [:]))
        XCTAssertEqual(P.packageWriteDecision(localDigest: localDigest, base: remoteDigest, remote: nil), .write(remoteMembers: [:]))
        // ベースが今の版 = 中身ごとのベースつきで書く
        XCTAssertEqual(
            P.packageWriteDecision(localDigest: localDigest, base: remoteDigest, remote: remote),
            .write(remoteMembers: members))
        // 同じ中身 = 書かない（ベースに依らない）
        XCTAssertEqual(P.packageWriteDecision(localDigest: remoteDigest, base: nil, remote: remote), .unchanged)
        XCTAssertEqual(P.packageWriteDecision(localDigest: remoteDigest, base: "old", remote: remote), .unchanged)
        // リモートがベースから進んだ・新規作成が重なった = 競合
        XCTAssertEqual(P.packageWriteDecision(localDigest: localDigest, base: "old", remote: remote), .conflict)
        XCTAssertEqual(P.packageWriteDecision(localDigest: localDigest, base: nil, remote: remote), .conflict)
        // 同名のファイル（単一ファイル形式で保存されていた）= 書く。フォルダ = 名前の衝突
        XCTAssertEqual(
            P.packageWriteDecision(
                localDigest: localDigest, base: nil, remote: .file(path: "Deck.key", entry: entry(sha: "9"))),
            .write(remoteMembers: [:]))
        XCTAssertEqual(
            P.packageWriteDecision(localDigest: localDigest, base: nil, remote: .directory(path: "Deck.key", mtime: nil)),
            .kindCollision)
    }

    func testDigestFromShasMatchesDigestFromEntries() {
        let members = ["a": entry(sha: "1"), "b/c": entry(sha: "2")]
        XCTAssertEqual(
            ManifestTree.packageDigest(shas: ["a": "1", "b/c": "2"]),
            ManifestTree.packageDigest(members: members))
        let node = ManifestTree.packageNode(path: "Deck.key", members: members)
        XCTAssertEqual(node.memberCount, 2)
        // ツリーが作るノードと同じ版
        let tree = ManifestTree(
            files: ["Deck.key/a": members["a"]!, "Deck.key/b/c": members["b/c"]!],
            packages: .extensions(["key"]))
        XCTAssertEqual(tree.node(at: "Deck.key"), node)
    }

    // MARK: - フォルダの削除・移動の対象

    func testTrackedFilesOpensPackages() {
        let tree = ManifestTree(files: [
            "t/Deck.key/Index/Document.iwa": entry(sha: "1"),
            "t/notes.txt": entry(sha: "2"),
            "t/sub/x.txt": entry(sha: "3"),
            "other/y.txt": entry(sha: "4"),
        ], packages: .extensions(["key"]))
        XCTAssertEqual(
            tree.trackedFiles(under: "t").map(\.path).sorted(),
            ["t/Deck.key/Index/Document.iwa", "t/notes.txt", "t/sub/x.txt"])
        XCTAssertEqual(
            tree.leaves(under: "t").map { "\($0.kind):\($0.path)" }.sorted(),
            ["file:t/notes.txt", "file:t/sub/x.txt", "package:t/Deck.key"])
        // 名前の前方一致だけのフォルダ（"t2"）は含めない
        XCTAssertTrue(ManifestTree(files: ["t2/z": entry(sha: "5")]).trackedFiles(under: "t").isEmpty)
    }
}
