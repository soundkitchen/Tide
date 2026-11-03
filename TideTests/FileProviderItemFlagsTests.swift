import FileProvider
import XCTest
import TideCore

/// 拡張の `FileProviderItem.fileSystemFlags`（#162）を直接固定する。`FileProviderItem.swift` は
/// project.yml でこのテストターゲットにも入れている — プロパティを消すと、このファイルが
/// コンパイルできなくなる（消すとシステムが「拡張子を隠す」を立てたプレースホルダを作る）。
final class FileProviderItemFlagsTests: XCTestCase {
    private let sha64 = String(repeating: "b", count: 64)

    private func file(
        _ path: String, permissions: ManifestFilePermissions = .none
    ) -> ManifestTree.Node {
        .file(path: path, entry: ManifestFileEntry(
            size: 1, mtime: "2026-11-03T00:00:00Z", sha256: sha64,
            s3VersionId: nil, etag: "e", deviceId: "d", uploadedAt: "2026-11-03T00:00:00Z",
            permissions: permissions))
    }

    /// TideCore の旗のビット値は FP の定数と同じ（拡張は rawValue をそのまま写す）。
    func testPolicyBitsMatchFileProviderConstants() {
        typealias P = FileProviderWritePolicy.FileSystemFlags
        let pairs: [(P, NSFileProviderFileSystemFlags)] = [
            (.userExecutable, .userExecutable),
            (.userReadable, .userReadable),
            (.userWritable, .userWritable),
            (.hidden, .hidden),
            (.pathExtensionHidden, .pathExtensionHidden),
        ]
        for (policy, fp) in pairs {
            XCTAssertEqual(policy.rawValue, fp.rawValue)
        }
    }

    /// どの種類の item にも「拡張子を隠す」を立てない。
    func testItemsNeverHidePathExtension() {
        let nodes: [ManifestTree.Node] = [
            file("Projects/README.md"),
            file("bin/run.sh", permissions: ManifestFilePermissions(executable: true, readOnly: true)),
            .directory(path: "Privates", mtime: nil),
            .directory(path: "", mtime: nil),
            .package(path: "a/App.xcodeproj", members: [:], digest: sha64, mtime: nil),
        ]
        for node in nodes {
            XCTAssertFalse(
                FileProviderItem(node: node).fileSystemFlags.contains(.pathExtensionHidden), node.path)
        }
    }

    /// ファイルはマニフェストの旗で決まる: 旗なし = rw-・実行 = rwx・読み取り専用 = r--。
    func testFileFlagsFollowManifestPermissions() {
        XCTAssertEqual(
            FileProviderItem(node: file("a.txt")).fileSystemFlags, [.userReadable, .userWritable])
        XCTAssertEqual(
            FileProviderItem(node: file("run.sh", permissions: ManifestFilePermissions(executable: true, readOnly: false)))
                .fileSystemFlags,
            [.userReadable, .userWritable, .userExecutable])
        XCTAssertEqual(
            FileProviderItem(node: file("ro.txt", permissions: ManifestFilePermissions(executable: false, readOnly: true)))
                .fileSystemFlags,
            [.userReadable])
    }

    /// フォルダとパッケージは rwx・ドット名は隠す。
    func testDirectoryPackageAndDotNames() {
        let rwx: NSFileProviderFileSystemFlags = [.userReadable, .userWritable, .userExecutable]
        XCTAssertEqual(FileProviderItem(node: .directory(path: "a", mtime: nil)).fileSystemFlags, rwx)
        XCTAssertEqual(
            FileProviderItem(node: .package(path: "a/Talk.key", members: [:], digest: sha64, mtime: nil))
                .fileSystemFlags,
            rwx)
        XCTAssertEqual(
            FileProviderItem(node: .directory(path: "p/.git", mtime: nil)).fileSystemFlags,
            rwx.union(.hidden))
        XCTAssertTrue(FileProviderItem(node: file(".syncignore")).fileSystemFlags.contains(.hidden))
        XCTAssertFalse(FileProviderItem(node: file(".hidden/visible.txt")).fileSystemFlags.contains(.hidden))
        XCTAssertFalse(FileProviderItem(node: .directory(path: "", mtime: nil)).fileSystemFlags.contains(.hidden))
    }

    /// 保存先の無い item（フォルダ・パッケージ）は、システムが渡した旗をそのまま返せる。
    func testSystemFlagsOverride() {
        let flags: NSFileProviderFileSystemFlags = [.userReadable, .userExecutable]
        XCTAssertEqual(
            FileProviderItem(node: .directory(path: "a", mtime: nil), systemFileSystemFlags: flags)
                .fileSystemFlags,
            flags)
    }

    /// 旗を変えると item の metadataVersion が変わる（ほかの端末へ届く）・contentVersion は変わらない。
    func testPermissionsChangeOnlyMetadataVersion() {
        let plain = FileProviderItem(node: file("run.sh")).itemVersion
        let exec = FileProviderItem(
            node: file("run.sh", permissions: ManifestFilePermissions(executable: true, readOnly: false))
        ).itemVersion
        XCTAssertNotEqual(plain.metadataVersion, exec.metadataVersion)
        XCTAssertEqual(plain.contentVersion, exec.contentVersion)
    }
}
