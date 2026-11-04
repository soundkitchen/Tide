import Foundation

/// `PackageKindOverrides` の永続の置き場（Issue #163）。`PersistedPathSet` 2 本を 1 つにまとめる。
///
/// **記録は S3 に書く前に行う**: 中身が書かれてからだと、その間にツリーが名前で畳み、システムの持つ
/// item と食い違う（複製の原因そのもの）。記録を失っても失うのは見え方だけで、S3 の中身は変わらない
/// （記録の無いパスは名前で畳むので、#163 以前と同じ振る舞いに戻る）。
///
/// 中身はレプリカに紐づくので、ほかのレジストリと同じくドメイン epoch 不一致で全体破棄される。
public struct PackageKindLedger: Sendable {
    private let folders: PersistedPathSet
    private let packages: PersistedPathSet

    public init(folders: PersistedPathSet, packages: PersistedPathSet) {
        self.folders = folders
        self.packages = packages
    }

    public func overrides() async -> PackageKindOverrides {
        let folderPaths = await folders.snapshot()
        let packagePaths = await packages.snapshot()
        return PackageKindOverrides(folders: folderPaths, packages: packagePaths)
    }

    /// 操作を適用する。戻り値は「ディスクまで記録できたか」。記録を伴わない操作は true。
    /// 上限超過や保存の失敗は false（呼び出し側は、記録が無いときの振る舞いに倒す）。
    @discardableResult
    public func apply(_ action: PackageKindAction, path: String) async -> Bool {
        switch action {
        case .none:
            return true
        case .clear:
            await folders.remove(path)
            await packages.remove(path)
            return true
        case .recordFolder:
            await packages.remove(path)
            return await folders.addDurably(path)
        case .recordPackage:
            await folders.remove(path)
            return await packages.addDurably(path)
        }
    }

    /// 移動の前に、配下の記録を新しいパスへ写す（旧パスの記録は残す = 途中で止まっても旧の見え方を保つ）。
    public func copySubtree(from: String, to: String) async {
        await folders.copySubtree(from: from, to: to)
        await packages.copySubtree(from: from, to: to)
    }

    /// path 自身と配下の記録を消す（削除・移動の完了）。
    public func removeSubtree(at path: String) async {
        await folders.removeSubtree(at: path)
        await packages.removeSubtree(at: path)
    }
}
