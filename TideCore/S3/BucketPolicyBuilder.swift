import Foundation

/// バケットポリシー（JSON 文字列）に「TLS 非使用リクエストを拒否する」Tide の statement を冪等にマージする
/// 純粋ロジック（C3 後半・Issue #26 / B）。S3 API（get/putBucketPolicy）から切り離し、ユニットテストで
/// 冪等性・他 statement 保持を固定する（`ensureLifecycleRules` の冪等マージと同型の純粋関数版）。
///
/// 方針: ユーザが作成した他の statement は保持し、`Sid == TideDenyInsecureTransport` の statement だけを
/// 最新の定義へ置換する（lifecycle の `tide-*` ID 扱いと対称）。
public enum BucketPolicyBuilder {
    /// Tide が管理する statement の固定 Sid。これを持つ statement だけを差し替え対象とみなす。
    public static let tideDenySid = "TideDenyInsecureTransport"

    public enum BucketPolicyError: Error, CustomStringConvertible {
        case unparseableExistingPolicy
        public var description: String {
            switch self {
            case .unparseableExistingPolicy:
                return "Existing bucket policy is not valid JSON; refusing to overwrite"
            }
        }
    }

    /// TLS 非使用（`aws:SecureTransport=false`）を全アクション Deny する Tide の statement。
    public static func denyStatement(bucket: String) -> [String: Any] {
        [
            "Sid": tideDenySid,
            "Effect": "Deny",
            "Principal": "*",
            "Action": "s3:*",
            "Resource": ["arn:aws:s3:::\(bucket)", "arn:aws:s3:::\(bucket)/*"],
            "Condition": ["Bool": ["aws:SecureTransport": "false"]]
        ]
    }

    /// 既存ポリシー JSON（nil/空 = 未設定）に Tide の TLS-deny statement をマージした JSON を返す。
    /// - 既存の同 Sid statement は除去してから付け直す（冪等＝重複しない）。他 statement は保持。
    /// - `Version` は既存を尊重、無ければ `"2012-10-17"`。
    /// - 既存が非空なのに JSON として読めない場合は**上書きせず throw**（ユーザ statement を失わない）。
    public static func mergeTLSDenyStatement(into existing: String?, bucket: String) throws -> String {
        var root: [String: Any] = [:]
        if let existing, !existing.isEmpty {
            guard let data = existing.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw BucketPolicyError.unparseableExistingPolicy
            }
            root = obj
        }

        // Statement は配列 or 単一オブジェクト（IAM 仕様）。**存在するのに配列/オブジェクトでない**（不正）なら
        // 黙って捨てず throw し、上書きで取りこぼすのを避ける（unparseable と対称＝「理解できないポリシーは
        // 壊さない」方針の徹底・PR #36 nit-4）。
        var statements: [[String: Any]]
        switch root["Statement"] {
        case nil:
            statements = []
        case let arr as [[String: Any]]:
            statements = arr
        case let single as [String: Any]:
            statements = [single]
        default:
            throw BucketPolicyError.unparseableExistingPolicy
        }
        statements.removeAll { ($0["Sid"] as? String) == tideDenySid }   // 既存 Tide statement を除去（冪等）
        statements.append(denyStatement(bucket: bucket))

        root["Version"] = (root["Version"] as? String) ?? "2012-10-17"
        root["Statement"] = statements

        let out = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        return String(decoding: out, as: UTF8.self)
    }

    /// 既存ポリシーに、当該 bucket 向けの Tide TLS-deny statement が**同内容で**既に入っているか。
    /// 真なら putBucketPolicy 不要（毎起動の無駄な書込を避ける）。key 順に依存しない比較。
    public static func isTLSDenyEnforced(in policy: String?, bucket: String) -> Bool {
        guard let policy, !policy.isEmpty, let data = policy.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return false
        }
        let want = denyStatement(bucket: bucket)
        return normalizedStatements(root["Statement"]).contains { stmt in
            (stmt["Sid"] as? String) == tideDenySid && jsonEqual(stmt, want)
        }
    }

    // MARK: - helpers

    /// IAM の `Statement` は配列でも単一オブジェクトでも合法。配列に正規化する。
    private static func normalizedStatements(_ raw: Any?) -> [[String: Any]] {
        if let arr = raw as? [[String: Any]] { return arr }
        if let single = raw as? [String: Any] { return [single] }
        return []
    }

    /// 2 つの JSON オブジェクトを、key 順に依存しない正規形（sortedKeys 直列化）で比較する。
    private static func jsonEqual(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        guard let da = try? JSONSerialization.data(withJSONObject: a, options: [.sortedKeys]),
              let db = try? JSONSerialization.data(withJSONObject: b, options: [.sortedKeys]) else {
            return false
        }
        return da == db
    }
}
