import Foundation
import Synchronization
import UniformTypeIdentifiers

/// パス要素の名前が macOS のパッケージ（Keynote のパッケージ形式・`.xcodeproj`・`.dSYM` など、
/// Finder が 1 つの書類として見せるフォルダ）かを決める（#140）。
///
/// File Provider はパッケージを「中身を持つ 1 つの item」として扱う（createItem の `url` は
/// パッケージのフォルダ・フォルダの item として返すと `itemKindMismatch`。2026-10-30 実機確定）。
/// マニフェストにはパッケージの中身がファイルごとに並ぶので、ツリー（`ManifestTree`）はこの判定で
/// パッケージを 1 ノードに畳む。
///
/// 本番の判定（`.system`）は**その Mac の型情報**（拡張子をフォルダの型として引いた
/// `UTType(filenameExtension:conformingTo: .directory)` が宣言済みの型で `.package` に適合するか）。fileproviderd 自身もその Mac の LaunchServices で決めているとみられるので、判定を
/// 合わせて食い違いを避ける（ユーザ確定 2026-10-30）。アプリを入れたり消したりして結果が変わると、
/// そのパスはフォルダ ⇄ パッケージを行き来する（id の接頭辞が変わる = 旧 id の削除 + 新 id の出現
/// として配られる）。
public struct PackageClassifier: Sendable {
    private let isPackageName: @Sendable (String) -> Bool

    public init(isPackageName: @escaping @Sendable (String) -> Bool) {
        self.isPackageName = isPackageName
    }

    /// パス要素 1 つ（`/` を含まない名前）がパッケージ名か。
    public func isPackage(name: String) -> Bool {
        isPackageName(name)
    }

    /// 何もパッケージとみなさない（パッケージ対応前と同じツリー）。
    public static let none = PackageClassifier { _ in false }

    /// その Mac の型情報で決める。結果は拡張子（小文字）ごとにプロセス内でキャッシュする
    /// （ツリーは数万パスから作り直すため、LaunchServices の照会を拡張子あたり 1 回に抑える）。
    public static let system: PackageClassifier = {
        let cache = Mutex<[String: Bool]>([:])
        return PackageClassifier { name in
            let ext = (name as NSString).pathExtension.lowercased()
            guard !ext.isEmpty else { return false }
            if let hit = cache.withLock({ $0[ext] }) { return hit }
            // フォルダの型として引く。既定（`conformingTo: .data`）はファイルの型を探すので、`.key` は
            // 単一ファイル形式の Keynote に、`.xcodeproj` は仮の型（dynamic）になってパッケージに当たらない。
            // 宣言の無い拡張子はここでも仮の型が返り、`.package` への適合を名乗ることがあるので外す。
            let type = UTType(filenameExtension: ext, conformingTo: .directory)
            let result = type.map { !$0.isDynamic && $0.conforms(to: .package) } ?? false
            cache.withLock { $0[ext] = result }
            return result
        }
    }()

    /// ツリーの既定の判定（#140）。ドメイン identifier の変更（"main" → "main2" = 作り直し）と
    /// 対で `.system` にした。作り直さずに判定だけ変えると、稼働中のレプリカの `.xcodeproj` などが
    /// フォルダの id（`d:`）のまま残り、item(for:) が種類違いで `noSuchItem` を返す。
    public static let active: PackageClassifier = .system

    /// テスト用: 拡張子（小文字・ドットなし）の集合で決める。
    public static func extensions(_ exts: Set<String>) -> PackageClassifier {
        PackageClassifier { name in
            let ext = (name as NSString).pathExtension.lowercased()
            return !ext.isEmpty && exts.contains(ext)
        }
    }
}
