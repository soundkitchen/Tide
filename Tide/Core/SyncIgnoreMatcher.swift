import Foundation

/// `.syncignore`（gitignore 構文の一般的サブセット）をパースして除外判定する不変マッチャ。
///
/// 対応構文（`docs/07-M3-IMPLEMENTATION-GUIDE.md` サブタスク B / `docs/08-IMPLEMENTATION-NOTES.md`）:
/// - `#` で始まる行はコメント、空行は無視
/// - 先頭 `!` は否定（再包含）。`\#` / `\!` で `#` / `!` をエスケープ
/// - 末尾 `/` はディレクトリ限定
/// - 先頭または中間の `/` はルートアンカー。スラッシュが無ければ任意階層でマッチ
/// - `*` は `/` 以外の任意、`?` は `/` 以外 1 文字、`**` はパスセグメントをまたぐ
///
/// セキュリティ: ユーザ正規表現は受け取らず、グロブを**トークン列**へコンパイルし、照合は
/// reachable-set DP（`isIgnored`）で行う。計算量は `O(パターン長 × パス長)` に**構造的に**有界で、
/// `*a*a*…` 系の多ワイルドカードパターンでも破滅的バックトラッキング（ReDoS）が起こらない（security F1 / L8）。
/// 以前は `NSRegularExpression`（ICU = バックトラッキング）で照合していたため、キャップ内のパターンでも
/// 多項式爆発でハングし得た。本実装で恒久解（線形時間グロブ照合への置換）に到達した。
///
/// `parse` 時のキャップ（`maxPatternLength` / `maxWildcardsPerPattern` / `maxMatchPathLength`）は
/// ReDoS 防御の load-bearing ではなくなったが、防御的なサニティ上限として保持する（資源消費の有界化）。
///
/// 全ストアドプロパティが Sendable な値型なので、`performFullScan` の `Task.detached` へ
/// スナップショットを安全に渡せる（値型 + `Sendable`）。
///
/// 既知の制限: 親ディレクトリが除外された配下のファイルを `!` で再包含する gitignore の挙動
/// （「除外ディレクトリ配下は再包含できない」）は厳密には再現しない。同一階層での否定は正しく動く。
struct SyncIgnoreMatcher: Sendable {
    /// `.syncignore` のバイト数上限。これを超える分は読み込み側で打ち切る。
    static let maxBytes = 256 * 1024
    /// パターン数上限。超過分は捨てる。
    static let maxPatterns = 10_000
    /// 1 パターン（1 行）の最大文字数。超過行は parse で破棄（防御的サニティ上限）。
    static let maxPatternLength = 256
    /// 1 パターンに含められる `*` / `?` の最大個数。超過行は parse で破棄。
    /// 照合は線形時間なので ReDoS 防御としては不要だが、極端なパターンを弾く防御的上限として保持する。
    static let maxWildcardsPerPattern = 8
    /// `isIgnored` が照合する相対パスの最大文字数。超過パスは除外判定をスキップ（= 除外しない＝安全側）。
    /// 実在 FS パスは PATH_MAX 内に収まるため実害はない（防御的上限）。
    static let maxMatchPathLength = 1024

    /// グロブをコンパイルしたトークン。すべて `/` 区切りのパス文字列に対して評価する。
    private enum Token: Sendable, Equatable {
        case literal(Character)  // その文字そのもの（`/` を含む）
        case anyOne              // `?` → `/` 以外の 1 文字
        case starNonSlash        // `*`（およびセグメント内 `**`）→ `/` 以外の 0 文字以上
        case slashStarSlash      // `**/` → 0 個以上のディレクトリ（任意文字列 + `/`）。後続の `/` を取り込む
        case dotStar             // 末尾 `**` → 残り全体（`/` を含む任意の 0 文字以上）
    }

    private struct Pattern: Sendable {
        let tokens: [Token]
        /// 先頭/中間に `/` があり、ルートからアンカーするか。
        let anchored: Bool
        /// 末尾 `/`（ディレクトリ配下のファイルにのみマッチ）。
        let dirOnly: Bool
        /// 先頭 `!`（再包含）。
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

            // 防御的サニティ上限: 長すぎる行 / ワイルドカード過多の行は破棄する。
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

            let tokens = Self.tokenize(pat)
            compiled.append(Pattern(tokens: tokens, anchored: anchored, dirOnly: dirOnly, negated: negated))
            sources.append(line)
        }
        return SyncIgnoreMatcher(patterns: compiled, sourceLines: sources)
    }

    /// 相対パス（POSIX 区切り、先頭 `/` なし）が除外対象か。
    /// gitignore と同様、後に書かれたパターンが優先（否定で再包含）。
    func isIgnored(_ relativePath: String) -> Bool {
        guard !patterns.isEmpty else { return false }
        // 防御的サニティ上限: 異常に長い入力は照合せず「除外しない」を返す（安全側）。
        guard relativePath.count <= Self.maxMatchPathLength else { return false }
        let pathChars = Array(relativePath)
        let n = pathChars.count
        var ignored = false
        for p in patterns where Self.matches(p, pathChars: pathChars, n: n) {
            ignored = !p.negated
        }
        return ignored
    }

    // MARK: - glob → tokens

    /// グロブを `/` 区切りパス向けのトークン列へ変換する。`globToRegex` の旧ロジックと 1:1 対応:
    /// - `*`（単独）/ セグメント内 `**` → `.starNonSlash`（`/` 以外 0 文字以上）
    /// - スラッシュ境界の `**/` → `.slashStarSlash`（後続 `/` を取り込む）
    /// - 末尾の `**` → `.dotStar`
    /// - `?` → `.anyOne`、その他（`/` 含む）→ `.literal`
    private static func tokenize(_ pat: String) -> [Token] {
        let chars = Array(pat)
        let n = chars.count
        var tokens: [Token] = []
        var i = 0
        // 隣接する `[^/]*` の縮約に相当。`starNonSlash` が連続しても等価なので 1 個に畳む。
        func appendStar() {
            if tokens.last != .starNonSlash { tokens.append(.starNonSlash) }
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
                            tokens.append(.slashStarSlash)  // `**/` → 0 個以上のディレクトリ
                            j += 1
                        } else {
                            tokens.append(.dotStar)          // 末尾 `**`
                        }
                    } else {
                        appendStar()                         // セグメント内の `**` は `*` 扱い
                    }
                    i = j
                } else {
                    appendStar()
                    i += 1
                }
            case "?":
                tokens.append(.anyOne)
                i += 1
            default:
                tokens.append(.literal(c))
                i += 1
            }
        }
        return tokens
    }

    // MARK: - 線形時間照合（reachable-set DP）

    /// `tokens` を「パス位置の到達集合」で評価する。各トークンは到達集合を O(n) で更新するので、
    /// 全体は `O(トークン数 × パス長)` に有界（バックトラッキングが無い＝ReDoS 不能）。
    /// アンカー/ディレクトリ限定/祖先マッチの境界規則は旧 `globToRegex` の前後置換と同値。
    private static func matches(_ p: Pattern, pathChars: [Character], n: Int) -> Bool {
        // 到達集合: cur[k] == true は「パス位置 k まで消費した状態に到達可能」を表す。
        var cur = [Bool](repeating: false, count: n + 1)

        // 前置: anchored は `^`（{0}）、unanchored は `^(?:.*/)?`（{0} ∪ {各 `/` の直後}）。
        cur[0] = true
        if !p.anchored {
            for k in 0..<n where pathChars[k] == "/" { cur[k + 1] = true }
        }

        for tok in p.tokens {
            var next = [Bool](repeating: false, count: n + 1)
            switch tok {
            case .literal(let c):
                for pos in 0..<n where cur[pos] && pathChars[pos] == c { next[pos + 1] = true }
            case .anyOne:  // `[^/]`
                for pos in 0..<n where cur[pos] && pathChars[pos] != "/" { next[pos + 1] = true }
            case .starNonSlash:  // `[^/]*`: 到達点から次の `/` までの非スラッシュ run を 1 パスで伸ばす
                var active = false
                for pos in 0...n {
                    if cur[pos] { active = true }
                    if active { next[pos] = true }
                    if pos < n && pathChars[pos] == "/" { active = false }
                }
            case .slashStarSlash:  // `(?:.*/)?`: 空、または「任意文字列 + `/`」
                // 空のオプション: 現在位置を素通し。
                for pos in 0...n where cur[pos] { next[pos] = true }
                // `.*/`: 到達済みの最小位置以降にある各 `/` の直後へ到達できる。
                if let minP = firstReachable(cur) {
                    for k in minP..<n where pathChars[k] == "/" { next[k + 1] = true }
                }
            case .dotStar:  // `.*`: 到達済みの最小位置から末尾までの任意位置へ到達できる。
                if let minP = firstReachable(cur) {
                    for q in minP...n { next[q] = true }
                }
            }
            cur = next
        }

        // 後置:
        // - dirOnly: `/.*$` → 到達点に `/` があれば（その配下にマッチ）true。
        // - 非 dirOnly: `(?:/.*)?$` → パス全体を消費（cur[n]）か、到達点に `/` があれば（祖先一致）true。
        if !p.dirOnly && cur[n] { return true }
        for pos in 0..<n where cur[pos] && pathChars[pos] == "/" { return true }
        return false
    }

    private static func firstReachable(_ set: [Bool]) -> Int? {
        for (i, v) in set.enumerated() where v { return i }
        return nil
    }
}
