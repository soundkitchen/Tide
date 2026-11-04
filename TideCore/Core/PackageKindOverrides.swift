import Foundation

/// fileproviderd とパッケージの判定が食い違ったパスの記録（Issue #163）。
///
/// fileproviderd はローカルのフォルダを `pkg` と `dir` に分けるが、`PackageClassifier` の名前の判定とは
/// 一致しない（属性 `com.apple.fileprovider.fpfs#P` があれば `pkg`・無ければ拡張子で決まる。`docs/08`）。
/// ツリーが名前だけで畳むと、システムが `dir` として持っている item に同じ名前の `k:` が現れて複製
/// （`* 2.xcodeproj`）ができ、逆向きは `itemKindMismatch` で S3 に上がらない。そこで、届いたテンプレートの
/// 種類を正とし、名前の判定と違うパスだけをここに持つ。ツリーの判定はこれを名前より優先する。
public struct PackageKindOverrides: Sendable, Equatable {
    /// 名前はパッケージだが、システムがフォルダとして持っているパス（畳まない）。
    public var folders: Set<String>
    /// 名前はパッケージでないが、システムがパッケージとして持っているパス（畳む）。
    public var packages: Set<String>

    public init(folders: Set<String> = [], packages: Set<String> = []) {
        self.folders = folders
        self.packages = packages
    }

    public static let none = PackageKindOverrides()

    /// そのパスをパッケージとして畳むか。
    public func isPackage(path: String, name: String, classifier: PackageClassifier) -> Bool {
        if folders.contains(path) { return false }
        if packages.contains(path) { return true }
        return classifier.isPackage(name: name)
    }
}

/// `PackageKindOverrides` の記録の操作（`FileProviderWritePolicy.packageKindAction` の結果）。
public enum PackageKindAction: Equatable, Sendable {
    /// 何もしない（追跡中の別の種類があり、台帳を書き換えるとシステムの持つ id と食い違う）。
    case none
    /// 名前どおりなので、そのパスの記録を消す。
    case clear
    /// フォルダとして記録する（名前はパッケージ）。
    case recordFolder
    /// パッケージとして記録する（名前はパッケージでない）。
    case recordPackage
}
