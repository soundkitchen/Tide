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
        case directory(path: String)

        /// 相対 POSIX パス（ルートディレクトリは `""`）。
        public var path: String {
            switch self {
            case .file(let path, _): return path
            case .directory(let path): return path
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
    /// パス → ノード（ルート `""` を含む）。
    private let nodesByPath: [String: Node]

    public init(files: [String: ManifestFileEntry]) {
        var children: [String: [String: Node]] = ["": [:]]  // dir → (childName → node)
        var nodes: [String: Node] = ["": .directory(path: "")]

        for (path, entry) in files {
            let components = path.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }

            // 中間ディレクトリを合成
            var dir = ""
            for component in components.dropLast() {
                let childPath = dir.isEmpty ? component : "\(dir)/\(component)"
                if nodes[childPath] == nil {
                    let node = Node.directory(path: childPath)
                    nodes[childPath] = node
                    children[dir, default: [:]][component] = node
                    children[childPath] = children[childPath] ?? [:]
                }
                dir = childPath
            }

            // ファイル本体。同名の合成ディレクトリが既にある場合（"a" と "a/b" が両方
            // ファイルとして存在する壊れたマニフェスト）はディレクトリを優先して捨てる。
            let name = components.last!
            if nodes[path]?.isDirectory != true {
                let node = Node.file(path: path, entry: entry)
                nodes[path] = node
                children[dir, default: [:]][name] = node
            }
        }

        self.nodesByPath = nodes
        self.childrenByDir = children.mapValues { byName in
            byName.sorted { $0.key < $1.key }.map(\.value)
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
