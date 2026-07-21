import XCTest
import GRDB
import TideCore
@testable import Tide

/// Issue #54: フルスキャン / `.syncignore` 走査の symlink `skipDescendants()` 誤用の回帰テスト。
///
/// deep enumeration は symlink（ディレクトリリンク含む）へそもそも再帰しないが、旧実装は
/// symlink item（＝ファイル）で `skipDescendants()` を呼んでおり、**無関係な隣接ディレクトリ**への
/// 再帰がスキップされていた。フルスキャンでは実在する追跡ファイルが foundPaths から欠落 →
/// 削除検出に乗って S3 へ誤 delete（実機発現・M1 からの潜在バグ）、`.syncignore` 走査では
/// 配下の `.syncignore` が層状マッチャから欠落する。
///
/// 発現は列挙順（APFS のハッシュ順）依存のため、多数の symlink とディレクトリを並べて
/// 「どの順で列挙されても全ファイル / 全 `.syncignore` が走査に載る」不変条件で固定し、さらに
/// **列挙順の前提条件**（symlink の後に未走査ディレクトリが並ぶ＝旧実装が失敗する条件）を
/// アサートしてガードの静かな失効を検出可能にする（PR #55 レビュー ④）。
/// あわせて「dir-symlink へ再帰しない」という load-bearing なプラットフォーム挙動も固定する
/// （レビュー ③・これが崩れると C2 のサンドボックス回避が回帰する）。
/// SyncEngine は実物を構築する（init は S3 へ出ない。スキャンも S3 非接触＝ダミー資格情報で安全）。
///
/// #64 補足: `performFullScan` は再帰下降（`singlePassScan`）へ書き換えられ enumerator /
/// `skipDescendants()` を使わなくなったが、本スイートは「symlink が何本あっても全ファイルが
/// 走査に載る・dir-symlink に降りない」という**終端不変条件**の回帰網としてそのまま維持する。
/// `loadLayeredIgnore`（pull 用に残置）は引き続き enumerator ベース＝skipDescendants 規約と
/// 列挙順の前提条件アサートがそちらで生きる。
@MainActor
final class FullScanSymlinkTests: XCTestCase {

    private func makeEngine(root: URL, db: LocalDatabase) throws -> SyncEngine {
        let (s3, config) = try makeOfflineS3AndConfig()
        return SyncEngine(db: db, s3: s3, syncRoot: root, deviceId: "devT", config: config)
    }

    /// fixture: ルート直下に「実ファイルを指す file-symlink」と「子ファイル入りディレクトリ」を
    /// 同数（12 組）並べ、さらに **root 外**のディレクトリ（子ファイル + `.syncignore` 入り）を指す
    /// dir-symlink を 1 本置く。
    /// - Returns: (子ファイル相対パス, symlink 相対パス（dir-symlink 含む）)
    private func makeInterleavedTree(
        root: URL, outsideBase: URL, withSyncignore: Bool = false
    ) throws -> (children: [String], symlinks: Set<String>) {
        let fm = FileManager.default
        try writeFile(root, "target.txt", Data("t".utf8))

        var children: [String] = []
        var symlinks: Set<String> = []
        for i in 0..<12 {
            let dirName = String(format: "d%02d", i)
            let child = "\(dirName)/child.txt"
            try writeFile(root, child, TestData.deterministicBytes(64, salt: UInt8(i)))
            children.append(child)
            if withSyncignore {
                try writeFile(root, "\(dirName)/.syncignore", Data("pat-\(i)\n".utf8))
            }
            let link = String(format: "s%02d.txt", i)
            try fm.createSymbolicLink(
                at: root.appendingPathComponent(link),
                withDestinationURL: root.appendingPathComponent("target.txt")
            )
            symlinks.insert(link)
        }

        // C2 の前提固定用: root 外の機密ディレクトリを指す dir-symlink（~/.ssh を指すリンクの模擬）。
        let outside = outsideBase.appendingPathComponent("outside", isDirectory: true)
        try writeFile(outside, "secret.txt", Data("secret".utf8))
        try writeFile(outside, ".syncignore", Data("outside-pat\n".utf8))
        try fm.createSymbolicLink(
            at: root.appendingPathComponent("linkdir"),
            withDestinationURL: outside
        )
        symlinks.insert("linkdir")

        return (children, symlinks)
    }

    /// 前提条件（レビュー ④）: 「symlink item の後に、まだ走査されていないディレクトリが列挙される」
    /// 順序が fixture に少なくとも 1 箇所あることを確認する。旧実装（symlink で skipDescendants）は
    /// この条件下で次のディレクトリへの再帰を失う＝これが成立しない列挙順では回帰テストの
    /// 赤→緑の実効性が静かに失効するため、失効を fixture 設計の失敗として顕在化させる。
    private func assertEnumerationOrderPrecondition(root: URL, file: StaticString = #filePath, line: UInt = #line) {
        let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
        var firstSymlinkIndex: Int?
        var lastDirIndex = -1
        var index = 0
        while let url = walker?.nextObject() as? URL {
            let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if v?.isSymbolicLink == true, firstSymlinkIndex == nil {
                firstSymlinkIndex = index
            }
            if v?.isDirectory == true {
                lastDirIndex = index
            }
            index += 1
        }
        guard let sym = firstSymlinkIndex else {
            return XCTFail("fixture に symlink が無い", file: file, line: line)
        }
        XCTAssertTrue(
            sym < lastDirIndex,
            "列挙順の前提（symlink の後に未走査ディレクトリが並ぶ）が不成立 — この環境では旧実装の回帰を検出できない。fixture の見直しが必要",
            file: file, line: line
        )
    }

    /// フルスキャン: symlink が何本あっても全子ファイルが走査に載る＝追跡ファイルが
    /// 削除検出に乗らない（旧実装は隣接ディレクトリの skip で delete 行が積まれた）。
    /// あわせて dir-symlink の配下（root 外）が同期対象に一切乗らないこと（C2）も固定する。
    func testFullScanFindsAllFilesDespiteFileSymlinks() async throws {
        let env = try makeTideTestEnv(prefix: "tide-scan-symlink")
        let tree = try makeInterleavedTree(root: env.root, outsideBase: env.base)
        assertEnumerationOrderPrecondition(root: env.root)

        // 全子ファイルを追跡中（stale な値 = size 不一致）として seed: 走査で見つかれば upload、
        // 走査から欠落すれば削除検出に落ちて delete 行として観測できる。
        for p in tree.children {
            try await seedFileRecord(env.db, path: p, sha: "stale", size: 1)
        }

        let engine = try makeEngine(root: env.root, db: env.db)
        await engine.triggerFullScan()

        let rows = try await env.db.pool.read { db in try UploadQueueRecord.fetchAll(db) }
        let deletes = rows.filter { $0.operation == "delete" }.map(\.path)
        XCTAssertTrue(deletes.isEmpty, "実在する追跡ファイルが削除検出に乗った（隣接 symlink による skip）: \(deletes)")

        let uploads = Set(rows.filter { $0.operation == "upload" }.map(\.path))
        for p in tree.children {
            XCTAssertTrue(uploads.contains(p), "\(p) が走査から欠落している")
        }
        // symlink 自身は同期対象に乗らない（C2 ゲート維持・レビュー ⑤: 名前集合で直接アサート）。
        XCTAssertTrue(uploads.isDisjoint(with: tree.symlinks), "symlink がキューに乗っている: \(uploads.intersection(tree.symlinks))")
        // dir-symlink へ再帰しない（C2・レビュー ③）: root 外の配下が同期対象に乗らない。
        XCTAssertTrue(
            uploads.allSatisfy { !$0.hasPrefix("linkdir/") },
            "dir-symlink の配下がアップロード対象に乗っている（enumerator が symlink を辿っている）: \(uploads.filter { $0.hasPrefix("linkdir/") })"
        )
    }

    /// `.syncignore` 走査（loadLayeredIgnore）: symlink が何本あっても全ディレクトリの
    /// `.syncignore` が層状マッチャに載る（旧実装は隣接ディレクトリ配下が欠落し得た）。
    /// dir-symlink 配下（root 外）の `.syncignore` は載らないこと（C2）も固定する。
    func testReloadIgnoreMatcherFindsAllSyncignoresDespiteFileSymlinks() async throws {
        let env = try makeTideTestEnv(prefix: "tide-ignore-symlink")
        _ = try makeInterleavedTree(root: env.root, outsideBase: env.base, withSyncignore: true)
        assertEnumerationOrderPrecondition(root: env.root)

        let engine = try makeEngine(root: env.root, db: env.db)
        await engine.reloadIgnoreMatcher()

        let dirs = Set(engine.activeIgnorePatterns.map(\.directory))
        for i in 0..<12 {
            let d = String(format: "d%02d", i)
            XCTAssertTrue(dirs.contains(d), ".syncignore(\(d)) が層状マッチャから欠落している")
        }
        XCTAssertFalse(dirs.contains("linkdir"), "dir-symlink 配下の .syncignore が読まれている（enumerator が symlink を辿っている）")
    }
}
