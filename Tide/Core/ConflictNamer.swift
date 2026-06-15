import Foundation

/// 復元時にローカルとリモートの SHA が衝突した場合のリネーム規則。
/// `foo.txt` → `foo (local copy 2026-05-24 12-34-56).txt`
/// バージョン復元で未同期のローカル編集を退避するときは `restored` ラベルを使う。
/// `foo.txt` → `foo (restored 2026-05-24 12-34-56).txt`
enum ConflictNamer {
    /// `YYYY-MM-DD HH-MM-SS`（24 時間・0 埋め・ロケール非依存）の固定書式。
    /// `Date.FormatStyle`（`.dateTime.year()…`）は `.month()` が略称・`.hour()` が 12 時間 + AM/PM・
    /// `at` 区切りのロケール表記になり、辞書順が時系列にならない（`Jun`/`Mar`… で並ぶ）ため使わない。
    /// `VerbatimFormatStyle` は Sendable なので `static let` のまま strict concurrency で安全。
    /// 区切りはすべてリテラル（`-` / 空白）＝コロン等を含まないので別途のサニタイズは不要。
    private static let timestampStyle = Date.VerbatimFormatStyle(
        format: "\(year: .padded(4))-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))-\(minute: .twoDigits)-\(second: .twoDigits)",
        timeZone: .current,
        calendar: Calendar(identifier: .gregorian)
    )

    static func localCopyRelativePath(
        for relativePath: String,
        at date: Date = Date()
    ) -> String {
        copyRelativePath(for: relativePath, label: "local copy", at: date)
    }

    /// バージョン復元で、未同期のローカル編集を上書きしないよう退避コピー先を作る。
    static func restoredCopyRelativePath(
        for relativePath: String,
        at date: Date = Date()
    ) -> String {
        copyRelativePath(for: relativePath, label: "restored", at: date)
    }

    /// `<stem> (<label> YYYY-MM-DD HH-MM-SS).<ext>` を組む共通ロジック。
    private static func copyRelativePath(
        for relativePath: String,
        label: String,
        at date: Date
    ) -> String {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let last = parts.last else { return relativePath }

        let (stem, ext) = splitExtension(last)
        let stamp = date.formatted(timestampStyle)
        let newLast: String
        if ext.isEmpty {
            newLast = "\(stem) (\(label) \(stamp))"
        } else {
            newLast = "\(stem) (\(label) \(stamp)).\(ext)"
        }
        var newParts = parts
        newParts[newParts.count - 1] = newLast
        return newParts.joined(separator: "/")
    }

    /// "foo.tar.gz" → ("foo.tar", "gz") / "Makefile" → ("Makefile", "")
    private static func splitExtension(_ name: String) -> (String, String) {
        guard let dot = name.lastIndex(of: ".") else { return (name, "") }
        if dot == name.startIndex { return (name, "") }  // ".gitignore" 等
        return (String(name[..<dot]), String(name[name.index(after: dot)...]))
    }
}
