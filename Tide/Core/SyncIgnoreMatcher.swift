import Foundation

/// `.syncignore`（gitignore 構文の一般的サブセット）をパースして除外判定する不変マッチャ。
///
/// 対応構文（`docs/07-M3-IMPLEMENTATION-GUIDE.md` サブタスク B / `CLAUDE.md` 第 7 節）:
/// - `#` で始まる行はコメント、空行は無視
/// - 先頭 `!` は否定（再包含）。`\#` / `\!` で `#` / `!` をエスケープ
/// - 末尾 `/` はディレクトリ限定
/// - 先頭または中間の `/` はルートアンカー。スラッシュが無ければ任意階層でマッチ
/// - `*` は `/` 以外の任意、`?` は `/` 以外 1 文字、`**` はパスセグメントをまたぐ
///
/// セキュリティ: ユーザ正規表現は受け取らず、グロブから境界付き正規表現を生成する。生成した正規表現を
/// `NSRegularExpression`（ICU = バックトラッキング）で照合するため、`*a*a*…` 系の多ワイルドカードパターン ×
/// 部分一致する長い入力では破滅的バックトラッキングが起こり得る（security F1 / L8）。これを**速攻ガード**で緩和:
/// パターン単位の長さ・ワイルドカード数に上限を設けて実証 PoC 級を `parse` で破棄し、照合入力長にも上限を設け、
/// 隣接する `[^/]*` を縮約する。これは PoC 級の遮断と入力の有界化であって線形時間の構造的保証ではない
/// （恒久解 = 線形時間グロブ照合への置換は M3 タスク）。
///
/// `NSRegularExpression` はマッチング用途ではスレッドセーフ（Apple ドキュメント）かつ生成後は不変なので、
/// 値型として `@unchecked Sendable` にしている（`performFullScan` の `Task.detached` へスナップショットを渡すため）。
///
/// 既知の制限: 親ディレクトリが除外された配下のファイルを `!` で再包含する gitignore の挙動
/// （「除外ディレクトリ配下は再包含できない」）は厳密には再現しない。同一階層での否定は正しく動く。
struct SyncIgnoreMatcher: @unchecked Sendable {
    /// `.syncignore` のバイト数上限。これを超える分は読み込み側で打ち切る。
    static let maxBytes = 256 * 1024
    /// パターン数上限。超過分は捨てる。
    static let maxPatterns = 10_000
    /// 1 パターン（1 行）の最大文字数。超過行は parse で破棄（ReDoS 速攻ガード: F1）。
    static let maxPatternLength = 256
    /// 1 パターンに含められる `*` / `?` の最大個数。超過行は parse で破棄。
    /// 多ワイルドカードによる多項式バックトラッキングを抑える。正当なパターンは通常これを大きく下回る。
    static let maxWildcardsPerPattern = 8
    /// `isIgnored` が照合する相対パスの最大文字数。超過パスは除外判定をスキップ（= 除外しない＝安全側）。
    /// 実在 FS パスは PATH_MAX 内に収まるため実害はない。攻撃者がマニフェスト経由で長大パスを注入する経路を遮断する。
    static let maxMatchPathLength = 1024

    private struct Pattern {
        let regex: NSRegularExpression
        let negated: Bool
    }

    private let patterns: [Pattern]

    /// 元の（コメント/空行を除いた）パターン行。Settings 表示用。
    let sourceLines: [String]

    private init(patterns: [Pattern], sourceLines: [String]) {
        self.patterns = patterns
        self.sourceLines = sourceLines
    }

    /// 空マッチャ（`.syncignore` が無い時）。
    static let empty = SyncIgnoreMatcher(patterns: [], sourceLines: [])

    /// 新規バケットのセットアップ時に `<syncRoot>/.syncignore` へ書き出す既定テンプレート。
    /// 再生成可能な開発ジャンクを既定で除外する。ユーザは自由に編集・削除でき、他デバイスにも同期される。
    /// （`.git/` は復旧目的のため意図的に含めない＝同期対象のまま。）
    static let defaultTemplate = """
        # Tide の既定除外パターン。自由に編集してください（この設定は他のデバイスにも同期されます）。
        # 行頭 # はコメント、空行は無視。末尾 / はディレクトリ限定。
        # 既存の同期済みファイルには影響しません（新規ファイルにのみ適用）。

        # 依存関係・ビルド成果物（再生成可能なので既定で除外）
        node_modules/
        .build/
        DerivedData/
        target/
        dist/
        build/
        out/

        # Python
        __pycache__/
        *.pyc
        .venv/
        venv/

        # その他のキャッシュ
        .cache/

        """

    static func parse(_ text: String) -> SyncIgnoreMatcher {
        var compiled: [Pattern] = []
        var sources: [String] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for rawLine in lines {
            if compiled.count >= maxPatterns { break }

            // 末尾の空白（CR 含む）を除去。git の挙動。`\ ` エスケープは非対応。
            var line = String(rawLine)
            while let last = line.last, last == " " || last == "\t" || last == "\r" {
                line.removeLast()
            }
            if line.isEmpty { continue }
            if line.hasPrefix("#") { continue }

            // ReDoS 速攻ガード (F1): 長すぎる行 / ワイルドカード過多の行は破棄する。
            // 否定 `!` は機密網 (HardcodedIgnoreRules) を覆せないため、破棄しても機密が再包含されることはない。
            if line.count > maxPatternLength { continue }
            let wildcardCount = line.reduce(0) { $0 + (($1 == "*" || $1 == "?") ? 1 : 0) }
            if wildcardCount > maxWildcardsPerPattern { continue }

            var pat = line
            var negated = false
            if pat.hasPrefix("!") {
                negated = true
                pat.removeFirst()
            } else if pat.hasPrefix("\\#") || pat.hasPrefix("\\!") {
                pat.removeFirst()  // エスケープ解除（先頭の `\` を落とす）
            }
            if pat.isEmpty { continue }

            // 末尾 `/` → ディレクトリ限定
            var dirOnly = false
            if pat.hasSuffix("/") {
                dirOnly = true
                pat.removeLast()
                if pat.isEmpty { continue }
            }

            // アンカー判定: 先頭または中間に `/` があるか
            let anchored: Bool
            if pat.hasPrefix("/") {
                anchored = true
                pat.removeFirst()
            } else {
                anchored = pat.contains("/")
            }
            if pat.isEmpty { continue }

            let regexStr = Self.globToRegex(pat, anchored: anchored, dirOnly: dirOnly)
            guard let re = try? NSRegularExpression(pattern: regexStr) else { continue }
            compiled.append(Pattern(regex: re, negated: negated))
            sources.append(line)
        }
        return SyncIgnoreMatcher(patterns: compiled, sourceLines: sources)
    }

    /// 相対パス（POSIX 区切り、先頭 `/` なし）が除外対象か。
    /// gitignore と同様、後に書かれたパターンが優先（否定で再包含）。
    func isIgnored(_ relativePath: String) -> Bool {
        guard !patterns.isEmpty else { return false }
        // ReDoS 速攻ガード (F1): 異常に長い入力は照合せず「除外しない」を返す（安全側）。
        // 実在 FS パスは PATH_MAX 内なので実害なし。攻撃者注入の長大パスでの照合爆発を防ぐ。
        guard relativePath.count <= Self.maxMatchPathLength else { return false }
        let range = NSRange(relativePath.startIndex..., in: relativePath)
        var ignored = false
        for p in patterns where p.regex.firstMatch(in: relativePath, options: [], range: range) != nil {
            ignored = !p.negated
        }
        return ignored
    }

    // MARK: - glob → regex

    /// グロブパターンを、パス全体にマッチする境界付き正規表現へ変換する。
    /// `dirOnly` のときはディレクトリ配下のファイルにのみ、そうでなければパス自身か祖先ディレクトリにマッチ。
    private static func globToRegex(_ pat: String, anchored: Bool, dirOnly: Bool) -> String {
        let chars = Array(pat)
        let n = chars.count
        var re = ""
        var i = 0
        // 隣接する `[^/]*` の縮約（ReDoS 速攻ガード: F1）。`[^/]*[^/]*` は `[^/]*` と等価なので、
        // 冗長な量化子の重なり（バックトラッキングの曖昧さの源）を取り除く。
        func appendStarSegment() {
            if !re.hasSuffix("[^/]*") { re += "[^/]*" }
        }
        while i < n {
            let c = chars[i]
            switch c {
            case "*":
                if i + 1 < n && chars[i + 1] == "*" {
                    var j = i
                    while j < n && chars[j] == "*" { j += 1 }
                    let prevIsSlash = (i == 0) || (chars[i - 1] == "/")
                    let nextIsSlash = (j >= n) || (chars[j] == "/")
                    if prevIsSlash && nextIsSlash {
                        if j < n && chars[j] == "/" {
                            re += "(?:.*/)?"   // `**/` → 0 個以上のディレクトリ
                            j += 1
                        } else {
                            re += ".*"          // 末尾 `**`
                        }
                    } else {
                        appendStarSegment()     // セグメント内の `**` は `*` 扱い
                    }
                    i = j
                } else {
                    appendStarSegment()
                    i += 1
                }
            case "?":
                re += "[^/]"
                i += 1
            default:
                re += NSRegularExpression.escapedPattern(for: String(c))
                i += 1
            }
        }
        var full = anchored ? "^" : "^(?:.*/)?"
        full += re
        if dirOnly {
            full += "/.*$"          // ディレクトリ配下のファイルにマッチ
        } else {
            full += "(?:/.*)?$"     // パス自身、または祖先ディレクトリとしてマッチ
        }
        return full
    }
}
