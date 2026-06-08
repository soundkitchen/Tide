import Foundation

/// アップロード中にローカルファイルが変化していないか（torn read 防止）を判定する純粋関数。
///
/// 開始時の stat（size, mtime）と「読み終え後」の stat を比較し、**size 変化 or mtime 前進**が
/// あれば「不安定（＝読込中に書き換えられた）」とみなす。通常の書込は必ず mtime を更新するので、
/// 内容の変化はこの 2 値で捕捉できる。両 stat とも単一 `NoFollowFileReader` の同じ FD（同一 inode）
/// から取るので、パス再 stat の TOCTOU は無い。
///
/// 用途: `Uploader`（シングルパートは PUT 前、マルチパートは completeMultipartUpload 前）で再 stat し、
/// 不安定なら `SyncError.fileChangedDuringUpload` を投げて **torn な内容を現行版にコミットしない**（L6）。
enum StabilityCheck {
    /// `expected`（読込開始時）と `final`（読み終え後）が同一なら安定（true）。
    static func isStable(
        expectedSize: Int64, expectedMtime: Date,
        finalSize: Int64, finalMtime: Date
    ) -> Bool {
        finalSize == expectedSize && finalMtime == expectedMtime
    }

    /// `NoFollowFileReader.FileInfo` を直接受ける糖衣。
    static func isStable(
        expected: NoFollowFileReader.FileInfo,
        final: NoFollowFileReader.FileInfo
    ) -> Bool {
        isStable(
            expectedSize: expected.size, expectedMtime: expected.mtime,
            finalSize: final.size, finalMtime: final.mtime
        )
    }
}
