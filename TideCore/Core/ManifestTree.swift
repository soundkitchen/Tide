import Foundation

/// マニフェストの平坦な `[相対パス: ManifestFileEntry]` から、File Provider の列挙に使う
/// ディレクトリツリーを合成する純粋型（M5 Phase 3）。
///
/// - ディレクトリはマニフェストに実体を持たない（ファイルパスの中間コンポーネントから合成する）。
/// - パスは常に相対 POSIX（File Provider の item identifier と 1:1）。ルートは空文字 `""`。
/// - 入力パスは呼び出し側（`ManifestSnapshotLoader`）で `PathValidator` 済みの前提。
public struct ManifestTree: Sendable {
    public enum Node: Sendable, Equatable {
        case file(path: String, entry: ManifestFileEntry)
        /// `mtime` は配下ファイルの最大 mtime（合成値・M5 Phase 4 = Finder の 1970 表示解消）。
        /// ルート（`""`）は常に nil — `item(for:)` の root 高速パスがマニフェスト非依存のため、
        /// 経路によって root の itemVersion が揺れないよう固定する。
        case directory(path: String, mtime: Date?)

        /// 相対 POSIX パス（ルートディレクトリは `""`）。
        public var path: String {
            switch self {
            case .file(let path, _): return path
            case .directory(let path, _): return path
            }
        }

        /// 表示名（最終コンポーネント）。ルートは `""`。
        public var name: String {
            path.split(separator: "/").last.map(String.init) ?? ""
        }

        public var isDirectory: Bool {
            if case .directory = self { return true }
            return false
        }
    }

    /// ディレクトリパス（`""` = ルート）→ 直下の子ノード（名前昇順）。
    private let childrenByDir: [String: [Node]]
    /// パス → ノード（ルート `""` を含む）。増分列挙の diff（`ManifestTreeDiff`）が全走査する。
    public let nodesByPath: [String: Node]

    public init(files: [String: ManifestFileEntry]) {
        var children: [String: [String: Node]] = ["": [:]]  // dir → (childName → node)
        var nodes: [String: Node] = ["": .directory(path: "", mtime: nil)]

        for (path, entry) in files {
            let components = path.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }

            // 中間ディレクトリを合成。「同名がファイルとして先に挿入済み」の場合も
            // ディレクトリで**置換**する（ガードをファイル挿入側と対称にする）。
            // さもないと Dictionary の走査順次第で directory-wins 規則が破れ、
            // 非フォルダを親に持つ到達不能ノードができる（PR #50 レビュー #1）。
            var dir = ""
            for component in components.dropLast() {
                let childPath = dir.isEmpty ? component : "\(dir)/\(component)"
                if nodes[childPath]?.isDirectory != true {
                    let node = Node.directory(path: childPath, mtime: nil)
                    nodes[childPath] = node
                    children[dir, default: [:]][component] = node
                    children[childPath] = children[childPath] ?? [:]
                }
                dir = childPath
            }

            // ファイル本体。同名の合成ディレクトリが既にある場合（"a" と "a/b.txt" が両方
            // 存在する壊れたマニフェスト）はディレクトリを優先して捨てる。
            let name = components.last!
            if nodes[path]?.isDirectory != true {
                let node = Node.file(path: path, entry: entry)
                nodes[path] = node
                children[dir, default: [:]][name] = node
            }
        }

        // ディレクトリの合成 mtime（配下ファイルの最大値・ルートは対象外）は、構造が確定した後に
        // **生き残ったファイルノードのみ**から畳み込む。挿入時に畳み込むと、file→directory 置換
        // （壊れたマニフェスト）で置換済みファイルの mtime が残留し、Dictionary の走査順（プロセス
        // ごとに不定）で結果が変わる＝世代間 diff が幻のディレクトリ更新を出す（PR #51 レビュー #2）。
        var dirMtimes: [String: Date] = [:]
        for node in nodes.values {
            guard case .file(let path, let entry) = node,
                  let mtime = ISO8601.parse(entry.mtime) else { continue }
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

    /// `dirPath` 直下の子（名前昇順）。ディレクトリが存在しなければ nil。
    public func children(of dirPath: String) -> [Node]? {
        childrenByDir[dirPath]
    }

    /// パスのノード。ルートは `""`。
    public func node(at path: String) -> Node? {
        nodesByPath[path]
    }
}
