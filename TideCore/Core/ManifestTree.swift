import CryptoKit
import Foundation

/// マニフェストの平坦な `[相対パス: ManifestFileEntry]` から、File Provider の列挙に使う
/// ディレクトリツリーを合成する純粋型（M5 Phase 3）。
///
/// - ディレクトリはマニフェストに実体を持たない（ファイルパスの中間コンポーネントから合成する）。
/// - パスは常に相対 POSIX（File Provider の item identifier と 1:1）。ルートは空文字 `""`。
/// - 入力パスは呼び出し側（`ManifestSnapshotLoader`）で `PathValidator` 済みの前提。
/// - **パッケージ（#140）**: パス要素がパッケージ名（`PackageClassifier`）になった所で、その先を
///   1 つの `.package` ノードに畳む。中身は子ノードとして出さない（File Provider はパッケージを
///   中身を持つ 1 つの item として扱う）。入れ子のパッケージは一番外側だけを畳む。パスの最後の
///   要素（ファイル名）は判定しない — 単一ファイル形式の `Deck.key` はファイルのまま。
public struct ManifestTree: Sendable {
    public enum Node: Sendable, Equatable {
        case file(path: String, entry: ManifestFileEntry)
        /// `mtime` は配下ファイルの最大 mtime（合成値・M5 Phase 4 = Finder の 1970 表示解消）。
        /// ルート（`""`）は常に nil — `item(for:)` の root 高速パスがマニフェスト非依存のため、
        /// 経路によって root の itemVersion が揺れないよう固定する。
        case directory(path: String, mtime: Date?)
        /// パッケージ（#140）。`members` はパッケージ内の相対パス → entry（マニフェストの
        /// `<path>/<相対パス>` のファイル）。`digest` は中身の版（`ManifestTree.packageDigest`）、
        /// `mtime` は中身の最大 mtime。
        case package(path: String, members: [String: ManifestFileEntry], digest: String, mtime: Date?)

        /// ノードの種類。id の接頭辞（`f:` / `d:` / `k:`）と 1:1 で、種類の変化は差分で
        /// 「旧 id の削除 + 新 id の出現」に分解する（`ManifestTreeDiff`）。
        public enum Kind: Sendable, Equatable {
            case file, directory, package
        }

        public var kind: Kind {
            switch self {
            case .file: return .file
            case .directory: return .directory
            case .package: return .package
            }
        }

        /// 相対 POSIX パス（ルートディレクトリは `""`）。
        public var path: String {
            switch self {
            case .file(let path, _): return path
            case .directory(let path, _): return path
            case .package(let path, _, _, _): return path
            }
        }

        /// 表示名（最終コンポーネント）。ルートは `""`。
        public var name: String {
            path.split(separator: "/").last.map(String.init) ?? ""
        }

        /// 合成ディレクトリか。**パッケージは false**（子を持つが、File Provider には中身を持つ
        /// 1 つの item として見せる）。
        public var isDirectory: Bool {
            if case .directory = self { return true }
            return false
        }

        public var isPackage: Bool {
            if case .package = self { return true }
            return false
        }

        /// パッケージの中身の件数（パッケージ以外は 0）。
        public var memberCount: Int {
            if case .package(_, let members, _, _) = self { return members.count }
            return 0
        }
    }

    /// ディレクトリパス（`""` = ルート）→ 直下の子ノード（名前昇順）。
    private let childrenByDir: [String: [Node]]
    /// パス → ノード（ルート `""` を含む）。増分列挙の diff（`ManifestTreeDiff`）が全走査する。
    public let nodesByPath: [String: Node]

    /// - Parameter packages: パッケージ名の判定（#140）。既定は `PackageClassifier.active`。
    public init(files: [String: ManifestFileEntry], packages: PackageClassifier = .active) {
        var children: [String: [String: Node]] = ["": [:]]  // dir → (childName → node)
        var nodes: [String: Node] = ["": .directory(path: "", mtime: nil)]
        // パッケージのパス → (親ディレクトリ, 名前, 中身)。構造が確定した後でノードにする。
        var packageMembers: [String: (parent: String, name: String, members: [String: ManifestFileEntry])] = [:]

        for (path, entry) in files {
            let components = path.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }

            // 中間ディレクトリを合成。「同名がファイルとして先に挿入済み」の場合も
            // ディレクトリで**置換**する（ガードをファイル挿入側と対称にする）。
            // さもないと Dictionary の走査順次第で directory-wins 規則が破れ、
            // 非フォルダを親に持つ到達不能ノードができる（PR #50 レビュー #1）。
            // 中間要素がパッケージ名なら、そこから先はパッケージの中身として集める（#140）。
            var dir = ""
            var packaged = false
            for (index, component) in components.dropLast().enumerated() {
                let childPath = dir.isEmpty ? component : "\(dir)/\(component)"
                if packages.isPackage(name: component) {
                    let relative = components[(index + 1)...].joined(separator: "/")
                    packageMembers[childPath, default: (dir, component, [:])].members[relative] = entry
                    packaged = true
                    break
                }
                if nodes[childPath]?.isDirectory != true {
                    let node = Node.directory(path: childPath, mtime: nil)
                    nodes[childPath] = node
                    children[dir, default: [:]][component] = node
                    children[childPath] = children[childPath] ?? [:]
                }
                dir = childPath
            }
            if packaged { continue }

            // ファイル本体。同名の合成ディレクトリが既にある場合（"a" と "a/b.txt" が両方
            // 存在する壊れたマニフェスト）はディレクトリを優先して捨てる。
            let name = components.last!
            if nodes[path]?.isDirectory != true {
                let node = Node.file(path: path, entry: entry)
                nodes[path] = node
                children[dir, default: [:]][name] = node
            }
        }

        // パッケージのノード（#140）。同名のファイルがあればパッケージで置換する（directory-wins と
        // 同じ考え方 = 中身を持つ側を残す。名前の判定は一貫しているので同名のディレクトリは生じない）。
        for (packagePath, info) in packageMembers {
            let node = Self.packageNode(path: packagePath, members: info.members)
            nodes[packagePath] = node
            children[info.parent, default: [:]][info.name] = node
        }

        // ディレクトリの合成 mtime（配下ファイルの最大値・ルートは対象外）は、構造が確定した後に
        // **生き残ったファイルノードのみ**から畳み込む。挿入時に畳み込むと、file→directory 置換
        // （壊れたマニフェスト）で置換済みファイルの mtime が残留し、Dictionary の走査順（プロセス
        // ごとに不定）で結果が変わる＝世代間 diff が幻のディレクトリ更新を出す（PR #51 レビュー #2）。
        var dirMtimes: [String: Date] = [:]
        for node in nodes.values {
            let path: String
            let mtime: Date
            switch node {
            case .file(let p, let entry):
                guard let parsed = ISO8601.parse(entry.mtime) else { continue }
                (path, mtime) = (p, parsed)
            case .package(let p, _, _, let packageMtime):
                guard let packageMtime else { continue }
                (path, mtime) = (p, packageMtime)
            case .directory:
                continue
            }
            var ancestor = ""
            for component in path.split(separator: "/").dropLast() {
                ancestor = ancestor.isEmpty ? String(component) : "\(ancestor)/\(component)"
                dirMtimes[ancestor] = max(dirMtimes[ancestor] ?? .distantPast, mtime)
            }
        }

        // finalize: 合成 mtime をディレクトリノードへ注入（構造パスは上で確定済み）
        func finalized(_ node: Node) -> Node {
            if case .directory(let path, _) = node, !path.isEmpty, let mtime = dirMtimes[path] {
                return .directory(path: path, mtime: mtime)
            }
            return node
        }
        self.nodesByPath = nodes.mapValues(finalized)
        self.childrenByDir = children.mapValues { byName in
            byName.sorted { $0.key < $1.key }.map { finalized($0.value) }
        }
    }

    /// 全ファイルノードとパッケージノードの相対パス（実体化バッジ・Issue #65 の dir 集計入力）。
    /// パッケージは 1 件として入る（中身のパスは入らない = fileproviderd の実体化セットも
    /// パッケージを 1 item として持つ・#140）。順序不定。
    public var filePaths: [String] {
        nodesByPath.values.compactMap { node -> String? in
            switch node {
            case .file(let path, _), .package(let path, _, _, _): return path
            case .directory: return nil
            }
        }
    }

    /// `path` がパッケージの中身なら、そのパッケージのノード（#140）。パッケージ自身・
    /// パッケージの外のパスは nil。
    public func enclosingPackage(of path: String) -> Node? {
        var prefix = ""
        for component in path.split(separator: "/").dropLast() {
            prefix = prefix.isEmpty ? String(component) : "\(prefix)/\(component)"
            if let node = nodesByPath[prefix] {
                if node.isPackage { return node }
            } else {
                return nil
            }
        }
        return nil
    }

    /// パッケージの中身の版（#140）。中身の「相対パス と sha256」を相対パス昇順に並べた列の
    /// sha256（64 桁の小文字 16 進）。ファイルの sha と同じ形なので、FP の版の符号化と
    /// `FileProviderWritePolicy.baseSha` をそのまま通る。中身のパス・内容のどちらが変わっても変わり、
    /// mtime だけの変化では変わらない。
    public static func packageDigest(members: [String: ManifestFileEntry]) -> String {
        packageDigest(shas: members.mapValues(\.sha256))
    }

    /// 中身からパッケージのノードを作る（版 = `packageDigest`・mtime = 中身の最大値）。ツリーの構築と、
    /// FP 拡張が書いた直後に返す item が同じ版になるよう、両方がここを通る。
    public static func packageNode(path: String, members: [String: ManifestFileEntry]) -> Node {
        .package(
            path: path, members: members, digest: packageDigest(members: members),
            mtime: members.values.compactMap { ISO8601.parse($0.mtime) }.max())
    }

    /// `packageDigest(members:)` と同じ版を、中身の相対パス → sha256 から作る（ローカルの
    /// パッケージを書く前に、マニフェストの版と比べるため）。
    public static func packageDigest(shas: [String: String]) -> String {
        var hasher = SHA256()
        for relative in shas.keys.sorted() {
            hasher.update(data: Data(relative.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(shas[relative]!.utf8))
            hasher.update(data: Data([0x0a]))
        }
        return HashCalculator.hex(hasher.finalize())
    }

    /// `dirPath` 配下のマニフェストのファイル（パッケージは中身に開く）の相対パスと entry（#140）。
    /// フォルダの削除・移動の対象一覧。パッケージの中身を落とすと、フォルダと一緒に消える・動くはずの
    /// パッケージが旧の場所に残る。順序不定。
    public func trackedFiles(under dirPath: String) -> [(path: String, entry: ManifestFileEntry)] {
        let prefix = dirPath.isEmpty ? "" : dirPath + "/"
        var result: [(path: String, entry: ManifestFileEntry)] = []
        for (path, node) in nodesByPath where path.hasPrefix(prefix) && path != dirPath {
            switch node {
            case .file(_, let entry):
                result.append((path, entry))
            case .package(_, let members, _, _):
                for (relative, entry) in members { result.append((path + "/" + relative, entry)) }
            case .directory:
                break
            }
        }
        return result
    }

    /// `dirPath` 配下のファイルとパッケージのノード（item になる葉・#140）。順序不定。
    public func leaves(under dirPath: String) -> [Node] {
        let prefix = dirPath.isEmpty ? "" : dirPath + "/"
        return nodesByPath.compactMap { path, node in
            path.hasPrefix(prefix) && !node.isDirectory ? node : nil
        }
    }

    /// `dirPath` 直下の子（名前昇順）。ディレクトリが存在しなければ nil。
    public func children(of dirPath: String) -> [Node]? {
        childrenByDir[dirPath]
    }

    /// パスのノード。ルートは `""`。
    public func node(at path: String) -> Node? {
        nodesByPath[path]
    }
}
