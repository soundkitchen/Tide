import Foundation
import Darwin

/// ダウンロード時の一時ファイル置き場を決定するヘルパ。
///
/// 第一選択: `~/Library/Caches/Tide/tmp/`
/// 同期フォルダと別ボリュームになる場合は同期フォルダ配下の `.tide/tmp/` にフォールバックする
/// （`moveItem` を atomic な rename に保つため）。
public enum TideTmpDirectory {
    /// fpOnly（同期ルート無し = フォールバック先が無い）用: Caches 側 tmp をそのまま返す
    /// （M5 Track B-2）。S3 内復元の tmp は最後に S3 へ PUT して消すだけ（ローカルへの
    /// atomic move が無い）ので、同一ボリューム要件も無い。
    public static func cacheTmp() throws -> URL {
        try preferredCacheTmp()
    }

    public static func resolve(for syncRoot: URL) -> (tmpDir: URL, usedFallback: Bool) {
        let preferred: URL
        do {
            preferred = try preferredCacheTmp()
        } catch {
            return (fallback(in: syncRoot), true)
        }
        if sameVolume(preferred, syncRoot) {
            return (preferred, false)
        }
        return (fallback(in: syncRoot), true)
    }

    private static func preferredCacheTmp() throws -> URL {
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let url = caches.appendingPathComponent("Tide/tmp")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func fallback(in syncRoot: URL) -> URL {
        let url = syncRoot.appendingPathComponent(".tide/tmp")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        var sa = stat()
        var sb = stat()
        guard stat(a.path, &sa) == 0,
              stat(b.path, &sb) == 0 else { return false }
        return sa.st_dev == sb.st_dev
    }
}
