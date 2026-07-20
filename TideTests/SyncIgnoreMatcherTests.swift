import XCTest
import TideCore
@testable import Tide

final class SyncIgnoreMatcherTests: XCTestCase {
    private func m(_ text: String) -> SyncIgnoreMatcher { SyncIgnoreMatcher.parse(text) }

    func testEmptyMatcherIgnoresNothing() {
        XCTAssertFalse(SyncIgnoreMatcher.empty.isIgnored("foo.txt"))
        XCTAssertFalse(m("").isIgnored("foo.txt"))
    }

    func testStarExtension() {
        let s = m("*.log")
        XCTAssertTrue(s.isIgnored("foo.log"))
        XCTAssertTrue(s.isIgnored("a/b/foo.log"))   // スラッシュ無し → 任意階層
        XCTAssertFalse(s.isIgnored("foo.txt"))
        XCTAssertFalse(s.isIgnored("foo.log.txt"))  // 末尾一致のみ
    }

    func testDirectoryPattern() {
        let s = m("build/")
        XCTAssertTrue(s.isIgnored("build/output.o"))
        XCTAssertTrue(s.isIgnored("a/build/output.o"))
        XCTAssertFalse(s.isIgnored("build"))        // build という名前のファイルは対象外
        XCTAssertFalse(s.isIgnored("rebuild/x"))    // 前方一致ではない
    }

    func testRootAnchored() {
        let s = m("/root-only.txt")
        XCTAssertTrue(s.isIgnored("root-only.txt"))
        XCTAssertFalse(s.isIgnored("sub/root-only.txt"))
    }

    func testInternalSlashIsAnchored() {
        let s = m("doc/frotz")
        XCTAssertTrue(s.isIgnored("doc/frotz"))
        XCTAssertTrue(s.isIgnored("doc/frotz/file"))  // 祖先ディレクトリとしてマッチ
        XCTAssertFalse(s.isIgnored("a/doc/frotz"))
    }

    func testDoubleStarLeading() {
        let s = m("**/node_modules")
        XCTAssertTrue(s.isIgnored("node_modules/x"))
        XCTAssertTrue(s.isIgnored("a/b/node_modules/x"))
        XCTAssertFalse(s.isIgnored("a/node_modules_x/y"))
    }

    func testDoubleStarMiddle() {
        let s = m("a/**/b")
        XCTAssertTrue(s.isIgnored("a/b"))
        XCTAssertTrue(s.isIgnored("a/x/b"))
        XCTAssertTrue(s.isIgnored("a/x/y/b"))
        XCTAssertFalse(s.isIgnored("a/b2"))
    }

    func testTrailingDoubleStar() {
        let s = m("logs/**")
        XCTAssertTrue(s.isIgnored("logs/a"))
        XCTAssertTrue(s.isIgnored("logs/a/b.txt"))
        XCTAssertFalse(s.isIgnored("logs"))
    }

    func testQuestionMark() {
        let s = m("file?.txt")
        XCTAssertTrue(s.isIgnored("file1.txt"))
        XCTAssertFalse(s.isIgnored("file.txt"))
        XCTAssertFalse(s.isIgnored("file12.txt"))
    }

    func testNegationReinclude() {
        let s = m("*.log\n!important.log")
        XCTAssertTrue(s.isIgnored("foo.log"))
        XCTAssertFalse(s.isIgnored("important.log"))
        XCTAssertFalse(s.isIgnored("a/important.log"))  // 任意階層で再包含
    }

    func testCommentsAndBlankLines() {
        let s = m("# comment\n\n*.tmp\n   \n")
        XCTAssertTrue(s.isIgnored("x.tmp"))
        XCTAssertFalse(s.isIgnored("x.txt"))
        XCTAssertEqual(s.sourceLines, ["*.tmp"])
    }

    func testEscapedHash() {
        let s = m("\\#literal")
        XCTAssertTrue(s.isIgnored("#literal"))
    }

    func testCaseSensitive() {
        // gitignore 既定の case-sensitive 挙動
        let s = m("*.log")
        XCTAssertFalse(s.isIgnored("FOO.LOG"))
    }

    func testDotfilePattern() {
        let s = m(".cache")
        XCTAssertTrue(s.isIgnored(".cache"))
        XCTAssertTrue(s.isIgnored("sub/.cache"))
        XCTAssertTrue(s.isIgnored(".cache/data"))
    }

    func testDefaultTemplateExcludesCommonJunk() {
        let s = SyncIgnoreMatcher.parse(SyncIgnoreMatcher.defaultTemplate)
        XCTAssertTrue(s.isIgnored("node_modules/left-pad/index.js"))
        XCTAssertTrue(s.isIgnored("sub/node_modules/x"))
        XCTAssertTrue(s.isIgnored("__pycache__/foo.cpython-311.pyc"))
        XCTAssertTrue(s.isIgnored("app/foo.pyc"))
        XCTAssertTrue(s.isIgnored(".build/debug/x"))
        XCTAssertTrue(s.isIgnored("DerivedData/Tide/x"))
        // 通常ファイルは除外されない
        XCTAssertFalse(s.isIgnored("src/main.swift"))
        XCTAssertFalse(s.isIgnored("README.md"))
        // .git は既定テンプレートでは除外しない（復旧目的で同期対象のまま）
        XCTAssertFalse(s.isIgnored(".git/HEAD"))
    }

    func testPatternCountCapDoesNotCrash() {
        let many = (0..<(SyncIgnoreMatcher.maxPatterns + 10))
            .map { "p\($0)" }
            .joined(separator: "\n")
        let s = m(many)
        XCTAssertTrue(s.isIgnored("p0"))            // 先頭は採用される
        XCTAssertEqual(s.sourceLines.count, SyncIgnoreMatcher.maxPatterns)
    }

    // MARK: - 三状態評価（LayeredSyncIgnore の層合成に必要）

    func testEvaluateTriState() {
        let s = m("*.log\n!keep.log")
        XCTAssertEqual(s.evaluate("foo.log"), .ignored)       // 除外パターンにマッチ
        XCTAssertEqual(s.evaluate("keep.log"), .included)     // 否定で再包含
        XCTAssertEqual(s.evaluate("foo.txt"), .unmatched)     // どのパターンにもマッチ無し
        XCTAssertEqual(SyncIgnoreMatcher.empty.evaluate("x"), .unmatched)
    }

    // MARK: - LayeredSyncIgnore（ネスト .syncignore・階層オーバーライド）

    private func layered(_ map: [String: String]) -> LayeredSyncIgnore {
        LayeredSyncIgnore(matchers: map.mapValues { SyncIgnoreMatcher.parse($0) })
    }

    func testLayeredEmptyIgnoresNothing() {
        XCTAssertFalse(LayeredSyncIgnore.empty.isIgnored("a/b.txt"))
        XCTAssertEqual(LayeredSyncIgnore.empty.evaluate("a/b.txt"), .unmatched)
    }

    func testLayeredRootEquivalentToSingleMatcher() {
        // ルート 1 枚だけなら従来の単一マッチャと同値。
        let single = m("*.log")
        let lay = LayeredSyncIgnore(root: single)
        XCTAssertEqual(lay.isIgnored("foo.log"), single.isIgnored("foo.log"))
        XCTAssertEqual(lay.isIgnored("a/b/foo.log"), single.isIgnored("a/b/foo.log"))
        XCTAssertEqual(lay.isIgnored("foo.txt"), single.isIgnored("foo.txt"))
    }

    func testLayeredPatternsAreRelativeToTheirDirectory() {
        // a/b/.syncignore の `secret.txt` は a/b 配下にだけ効く（ルート相対では無い）。
        let lay = layered(["a/b": "secret.txt"])
        XCTAssertTrue(lay.isIgnored("a/b/secret.txt"))
        XCTAssertTrue(lay.isIgnored("a/b/deep/secret.txt"))  // スラッシュ無し → 配下の任意階層
        XCTAssertFalse(lay.isIgnored("secret.txt"))           // 別ディレクトリには効かない
        XCTAssertFalse(lay.isIgnored("a/secret.txt"))
        XCTAssertFalse(lay.isIgnored("a/c/secret.txt"))
    }

    func testLayeredRootAnchorIsRelativeToDirectory() {
        // 先頭 `/` は「その .syncignore のディレクトリ」にアンカーされる。
        let lay = layered(["a": "/top.txt"])
        XCTAssertTrue(lay.isIgnored("a/top.txt"))
        XCTAssertFalse(lay.isIgnored("a/sub/top.txt"))  // a 直下のみ
        XCTAssertFalse(lay.isIgnored("top.txt"))
    }

    func testLayeredDeeperOverridesShallowerReinclude() {
        // ルートで *.log 除外 → 深い層で否定再包含。深い層が勝つ。
        let lay = layered(["": "*.log", "keep": "!*.log"])
        XCTAssertTrue(lay.isIgnored("foo.log"))
        XCTAssertTrue(lay.isIgnored("other/foo.log"))   // keep 以外は除外のまま
        XCTAssertFalse(lay.isIgnored("keep/foo.log"))   // 深い層で再包含
        XCTAssertFalse(lay.isIgnored("keep/deep/foo.log"))
    }

    func testLayeredDeeperOverridesShallowerReExclude() {
        // ルートで再包含（!important.log）→ 深い層で再び除外。深い層が勝つ。
        let lay = layered(["": "*.log\n!important.log", "build": "important.log"])
        XCTAssertFalse(lay.isIgnored("important.log"))        // ルートで再包含
        XCTAssertTrue(lay.isIgnored("build/important.log"))   // 深い層で再除外
    }

    func testLayeredUnmatchedDeeperKeepsShallowerVerdict() {
        // 深い層が当該パスにマッチしなければ、浅い層の判定を維持する。
        let lay = layered(["": "*.log", "sub": "*.tmp"])
        XCTAssertTrue(lay.isIgnored("sub/foo.log"))   // sub/.syncignore は *.log に無関心 → ルートの除外が残る
        XCTAssertTrue(lay.isIgnored("sub/foo.tmp"))   // sub/.syncignore が除外
        XCTAssertFalse(lay.isIgnored("sub/foo.dat"))  // どの層もマッチしない
    }

    func testLayeredDirectoryOwnSyncignoreDoesNotApplyToItself() {
        // a/b/.syncignore は a/b 配下にのみ効き、a/b というディレクトリ自身（祖先評価）には効かない。
        let lay = layered(["a/b": "*"])
        XCTAssertTrue(lay.isIgnored("a/b/x"))   // 配下は除外
        XCTAssertFalse(lay.isIgnored("a/b"))    // ディレクトリ自身は対象外（自分のルールでは消せない）
    }

    func testDirectoryGroupsSortedShallowToDeep() {
        let lay = layered(["a/b": "x", "": "y", "a": "z"])
        XCTAssertEqual(lay.directoryGroups.map(\.directory), ["", "a", "a/b"])
        XCTAssertEqual(lay.fileCount, 3)
        // パターン無し（コメントのみ）のファイルは groups から除外される。
        let lay2 = layered(["": "*.log", "empty": "# only comment"])
        XCTAssertEqual(lay2.directoryGroups.map(\.directory), [""])
        XCTAssertEqual(lay2.fileCount, 1)
    }

    // MARK: - インプレース層差し替え（#64 patch 用 API）

    func testUpdatingLayerAddsAndReplaces() {
        let base = layered(["": "*.log"])
        // 追加: ネスト層が増える。
        let added = base.updatingLayer(directory: "sub", matcher: m("*.tmp"))
        XCTAssertEqual(added.directoryGroups.map(\.directory), ["", "sub"])
        XCTAssertTrue(added.isIgnored("sub/a.tmp"))
        XCTAssertTrue(base.hasLayer(directory: ""))
        XCTAssertFalse(base.hasLayer(directory: "sub"))  // 元の値は不変（値型）
        // 置換: 同一 dir の層を差し替えると評価結果が変わる。
        let replaced = base.updatingLayer(directory: "", matcher: m("*.dat"))
        XCTAssertFalse(replaced.isIgnored("a.log"))
        XCTAssertTrue(replaced.isIgnored("a.dat"))
    }

    func testUpdatingLayerRemovesOnNilAndEmpty() {
        let base = layered(["": "*.log", "sub": "*.tmp"])
        // nil = ファイル消滅/読込不能 → 層の除去。
        let removed = base.updatingLayer(directory: "sub", matcher: nil)
        XCTAssertEqual(removed.directoryGroups.map(\.directory), [""])
        XCTAssertFalse(removed.isIgnored("sub/a.tmp"))
        // 空パターン（コメントのみ）も init のフィルタで層の除去と同値。
        let emptied = base.updatingLayer(directory: "sub", matcher: m("# comment only"))
        XCTAssertEqual(emptied.directoryGroups.map(\.directory), [""])
        XCTAssertFalse(emptied.hasLayer(directory: "sub"))
    }

    // MARK: - ReDoS 速攻ガード (F1 / L8)

    /// k 個のワイルドカードを持つグロブを生成（`*s0*s1*…`）。
    private func glob(stars k: Int) -> String {
        (0..<k).map { "*s\($0)" }.joined()
    }

    func testPathologicalManyWildcardPatternDropped() {
        // 実証 PoC 級（多 `*`）は parse で破棄され、コンパイルされない＝ハングし得ない。
        let s = m(glob(stars: 15))
        XCTAssertEqual(s.sourceLines.count, 0)
        XCTAssertFalse(s.isIgnored("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab"))
    }

    func testWildcardCapBoundaryIsInclusive() {
        // ちょうど上限個（8）は採用、超過（9）は破棄。
        XCTAssertEqual(m(glob(stars: SyncIgnoreMatcher.maxWildcardsPerPattern)).sourceLines.count, 1)
        XCTAssertEqual(m(glob(stars: SyncIgnoreMatcher.maxWildcardsPerPattern + 1)).sourceLines.count, 0)
    }

    func testOverlongPatternLineDropped() {
        let longLine = String(repeating: "a", count: SyncIgnoreMatcher.maxPatternLength + 1)
        XCTAssertEqual(m(longLine).sourceLines.count, 0)
        // 上限ちょうどは採用される
        let okLine = String(repeating: "a", count: SyncIgnoreMatcher.maxPatternLength)
        XCTAssertEqual(m(okLine).sourceLines.count, 1)
    }

    func testOverlongMatchInputIsNotIgnored() {
        let s = m("*.log")
        // 通常長は従来どおりマッチ
        XCTAssertTrue(s.isIgnored("dir/app.log"))
        // 異常に長い入力は照合せず「除外しない」を返す（安全側）
        let huge = String(repeating: "a", count: SyncIgnoreMatcher.maxMatchPathLength + 1) + ".log"
        XCTAssertFalse(s.isIgnored(huge))
    }

    func testNormalPatternsStillWorkUnderCaps() {
        // ワイルドカード数が上限以下の正当パターンはキャップに引っかからない。
        let s = m("**/node_modules\na/**/*.log\n*.min.*.js")
        XCTAssertEqual(s.sourceLines.count, 3)
        XCTAssertTrue(s.isIgnored("x/node_modules/y"))
        XCTAssertTrue(s.isIgnored("a/deep/path/err.log"))
        XCTAssertTrue(s.isIgnored("vendor/jquery.min.slim.js"))
    }

    // MARK: - ReDoS 構造的解消 (F1 / L8): 線形時間照合

    func testPathologicalPatternMatchesInLinearTime() {
        // キャップ内（8 ワイルドカード）の病的パターン × maxMatchPathLength ちょうどの非一致入力。
        // 旧 NSRegularExpression では多項式バックトラッキングでハングし得たが、reachable-set DP は
        // O(パターン長 × パス長) に有界なので即座に返る（security F1 受け入れ基準）。
        let s = m(glob(stars: SyncIgnoreMatcher.maxWildcardsPerPattern))  // `*s0*s1…*s7`
        XCTAssertEqual(s.sourceLines.count, 1, "8 ワイルドカードは採用される")
        // 長さ上限ちょうど（= 照合スキップ対象外）で、リテラル `sN` に一致しない入力。
        let input = String(repeating: "s", count: SyncIgnoreMatcher.maxMatchPathLength)
        let start = Date()
        let result = s.isIgnored(input)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertFalse(result)
        XCTAssertLessThan(elapsed, 0.5, "病的パターン × 非一致入力でも即座に返る（ReDoS なし）")
    }

    /// 線形時間照合（新実装）が、旧 `NSRegularExpression` ベース実装（＝意味論の基準）と一致することを
    /// ランダムなパターン × パスで differential に検証する。意味論ドリフトの回帰検出。
    func testLinearMatcherMatchesReferenceRegex() {
        var rng = SeededRNG(seed: 0xC0FFEE)
        for _ in 0..<3000 {
            let pat = randomPattern(&rng)
            let path = randomPath(&rng)
            let actual = m(pat).isIgnored(path)
            let expected = Self.referenceIgnored(pat, path)
            XCTAssertEqual(actual, expected, "pattern=\(pat) path=\(path)")
        }
    }

    // MARK: - differential fuzz の補助

    /// 決定的 PRNG（SplitMix64）。テストの再現性のため固定シードで使う。
    private struct SeededRNG: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// トークン全 5 種（`*`=starNonSlash / `?`=anyOne / 先頭・中間 `**/`=slashStarSlash /
    /// 末尾 `**`=dotStar / literal）と、先頭 `/`・末尾 `/`（dirOnly）を differential に網羅するランダムグロブ。
    ///
    /// `**` は 1 個あたり `*` 2 個ぶんなので、`parse` のワイルドカード上限（8）を超えると `parse` が
    /// 当該行を破棄して参照オラクル（上限を適用しない）とズレる。そのため各 `**` の追加は予算ガード
    /// （`wildcards + 2 <= maxWildcardsPerPattern`）付きにし、ループの `*`/`?` も少なめに抑える。
    private func randomPattern(_ rng: inout SeededRNG) -> String {
        var wildcards = 0
        func canAddDoubleStar() -> Bool { wildcards + 2 <= SyncIgnoreMatcher.maxWildcardsPerPattern }

        let segCount = Int.random(in: 1...3, using: &rng)
        var segs: [String] = []
        for _ in 0..<segCount {
            let tokCount = Int.random(in: 1...3, using: &rng)
            var seg = ""
            for _ in 0..<tokCount {
                switch Int.random(in: 0...4, using: &rng) {
                case 2 where wildcards < 2: seg += "*"; wildcards += 1
                case 3 where wildcards < 2: seg += "?"; wildcards += 1
                case 1: seg += "b"
                default: seg += "a"
                }
            }
            segs.append(seg)
        }

        // 中間 `**/`（前後にセグメントがある位置へ `**` セグメントを挿入）。
        if segs.count >= 2 && canAddDoubleStar() && Bool.random(using: &rng) {
            segs.insert("**", at: Int.random(in: 1..<segs.count, using: &rng))
            wildcards += 2
        }

        var pat = segs.joined(separator: "/")

        // 先頭 `**/`。
        if canAddDoubleStar() && Bool.random(using: &rng) {
            pat = "**/" + pat
            wildcards += 2
        }
        // ルートアンカー。
        if Bool.random(using: &rng) { pat = "/" + pat }
        // 末尾: dirOnly（`/`）/ 末尾 `**`（`/**` → dotStar）/ なし のいずれか（排他）。
        switch Int.random(in: 0...2, using: &rng) {
        case 0: pat += "/"
        case 1 where canAddDoubleStar(): pat += "/**"; wildcards += 2
        default: break
        }
        return pat
    }

    /// `a` / `b` セグメントからなるランダム相対パス。
    private func randomPath(_ rng: inout SeededRNG) -> String {
        let segCount = Int.random(in: 1...4, using: &rng)
        var segs: [String] = []
        for _ in 0..<segCount {
            let len = Int.random(in: 1...3, using: &rng)
            var s = ""
            for _ in 0..<len { s += Bool.random(using: &rng) ? "a" : "b" }
            segs.append(s)
        }
        return segs.joined(separator: "/")
    }

    /// 旧実装（`globToRegex` + `NSRegularExpression`）による単一パターン照合。意味論の基準。
    /// fuzz は caps 内・コメント/否定なしのパターンのみ渡すので、parse 前処理はここでは簡略化している。
    private static func referenceIgnored(_ line: String, _ path: String) -> Bool {
        var pat = line
        var dirOnly = false
        if pat.hasSuffix("/") { dirOnly = true; pat.removeLast() }
        if pat.isEmpty { return false }
        let anchored: Bool
        if pat.hasPrefix("/") { anchored = true; pat.removeFirst() }
        else { anchored = pat.contains("/") }
        if pat.isEmpty { return false }
        let regexStr = referenceGlobToRegex(pat, anchored: anchored, dirOnly: dirOnly)
        guard let re = try? NSRegularExpression(pattern: regexStr) else { return false }
        let range = NSRange(path.startIndex..., in: path)
        return re.firstMatch(in: path, options: [], range: range) != nil
    }

    /// 旧 `SyncIgnoreMatcher.globToRegex` の逐語コピー（基準実装）。
    private static func referenceGlobToRegex(_ pat: String, anchored: Bool, dirOnly: Bool) -> String {
        let chars = Array(pat)
        let n = chars.count
        var re = ""
        var i = 0
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
                            re += "(?:.*/)?"
                            j += 1
                        } else {
                            re += ".*"
                        }
                    } else {
                        appendStarSegment()
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
            full += "/.*$"
        } else {
            full += "(?:/.*)?$"
        }
        return full
    }
}
