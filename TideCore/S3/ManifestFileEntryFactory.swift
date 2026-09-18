import Foundation

/// `ManifestFileEntry` の生成ファクトリ（Issue #118）。
///
/// 「S3 書込結果 → entry」のフィールド詰め（size / mtime / sha256 / versionId / etag / deviceId /
/// uploadedAt）は app（`Uploader` / ウィザード seed）・core（`S3RestoreService`）・FP 拡張
/// （`ExtensionWriter`）に複製されていた。entry 契約の変更（フィールド追加・符号化変更）を 1 箇所へ
/// 集約し、反映漏れ = **無音のマニフェスト乖離**を構造的に防ぐ。**PutObject / MPU complete /
/// CopyObject の結果から entry を作る経路は必ずここを通す**（素の `init` 直呼びは DB キャッシュ
/// からの再構成 = `ManifestReader` のような「S3 書込結果でない」経路に限る）。
extension ManifestFileEntry {
    /// 本体を S3 へ書いた（単発 PUT / マルチパート complete）結果から entry を作る。
    /// - Parameters:
    ///   - size: 書いた本体のバイト数。
    ///   - sha256: 本体の SHA-256 hex 小文字（送信した FD / Data から計算した値）。
    ///   - mtime: マニフェストへ記録するローカル mtime（呼び出し側の規約: アップロード = stat 実値・
    ///     復元 = 復元時刻・FP = `contentModified ?? now`）。ISO8601 UTC 秒精度で符号化する。
    ///   - put: S3 が返した versionId / etag。
    ///   - deviceId: 書き手のデバイス識別子。
    ///   - uploadedAt: 書込時刻（既定 = 今）。
    public static func uploaded(
        size: Int64,
        sha256: String,
        mtime: Date,
        put: TideS3Client.PutObjectResult,
        deviceId: String,
        uploadedAt: Date = Date()
    ) -> ManifestFileEntry {
        ManifestFileEntry(
            size: size,
            mtime: ISO8601.format(mtime),
            sha256: sha256,
            s3VersionId: put.versionId,
            etag: put.etag,
            deviceId: deviceId,
            uploadedAt: ISO8601.format(uploadedAt)
        )
    }

    /// `copyObject`（rename / reparent）の結果から entry を作る。内容不変なので size / mtime /
    /// sha256 は元 entry を**そのまま維持**し（[mtime 不変条件] と整合）、versionId / etag だけを
    /// コピー先オブジェクトのものへ差し替える。
    public static func copied(
        from source: ManifestFileEntry,
        copy: TideS3Client.PutObjectResult,
        deviceId: String,
        uploadedAt: Date = Date()
    ) -> ManifestFileEntry {
        ManifestFileEntry(
            size: source.size,
            mtime: source.mtime,
            sha256: source.sha256,
            s3VersionId: copy.versionId,
            etag: copy.etag,
            deviceId: deviceId,
            uploadedAt: ISO8601.format(uploadedAt)
        )
    }
}
