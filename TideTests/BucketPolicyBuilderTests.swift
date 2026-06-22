import XCTest
@testable import Tide

/// `BucketPolicyBuilder` の JSON マージ純粋ロジック（C3 後半・Issue #26 / B）を固定する。
/// 冪等性・他 statement 保持・single-object 正規化・unparseable 拒否を網羅。
final class BucketPolicyBuilderTests: XCTestCase {
    private let bucket = "tide-example-bucket"

    // 出力 JSON を [String: Any] に戻す。
    private func parse(_ json: String) throws -> [String: Any] {
        let data = try XCTUnwrap(json.data(using: .utf8))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func statements(_ root: [String: Any]) -> [[String: Any]] {
        (root["Statement"] as? [[String: Any]]) ?? []
    }

    private func tideStatements(_ root: [String: Any]) -> [[String: Any]] {
        statements(root).filter { ($0["Sid"] as? String) == BucketPolicyBuilder.tideDenySid }
    }

    // MARK: - マージ

    func testMergeIntoEmptyCreatesTideStatement() throws {
        let out = try BucketPolicyBuilder.mergeTLSDenyStatement(into: nil, bucket: bucket)
        let root = try parse(out)
        XCTAssertEqual(root["Version"] as? String, "2012-10-17")
        let tide = tideStatements(root)
        XCTAssertEqual(tide.count, 1)
        let s = try XCTUnwrap(tide.first)
        XCTAssertEqual(s["Effect"] as? String, "Deny")
        XCTAssertEqual(s["Principal"] as? String, "*")
        XCTAssertEqual(s["Action"] as? String, "s3:*")
        XCTAssertEqual(s["Resource"] as? [String], ["arn:aws:s3:::\(bucket)", "arn:aws:s3:::\(bucket)/*"])
        let cond = try XCTUnwrap(s["Condition"] as? [String: Any])
        let boolCond = try XCTUnwrap(cond["Bool"] as? [String: Any])
        XCTAssertEqual(boolCond["aws:SecureTransport"] as? String, "false")
    }

    func testMergeIntoEmptyStringTreatedAsNoPolicy() throws {
        let out = try BucketPolicyBuilder.mergeTLSDenyStatement(into: "", bucket: bucket)
        XCTAssertEqual(tideStatements(try parse(out)).count, 1)
    }

    func testMergePreservesOtherStatements() throws {
        let existing = """
        {"Version":"2012-10-17","Statement":[
          {"Sid":"UserAllowSomething","Effect":"Allow","Principal":{"AWS":"arn:aws:iam::123456789012:user/me"},"Action":"s3:GetObject","Resource":"arn:aws:s3:::\(bucket)/*"}
        ]}
        """
        let out = try BucketPolicyBuilder.mergeTLSDenyStatement(into: existing, bucket: bucket)
        let root = try parse(out)
        let all = statements(root)
        XCTAssertEqual(all.count, 2, "ユーザ statement + Tide statement")
        XCTAssertEqual(tideStatements(root).count, 1)
        XCTAssertTrue(all.contains { ($0["Sid"] as? String) == "UserAllowSomething" }, "ユーザ statement が保持される")
    }

    func testMergeIsIdempotent() throws {
        let first = try BucketPolicyBuilder.mergeTLSDenyStatement(into: nil, bucket: bucket)
        let second = try BucketPolicyBuilder.mergeTLSDenyStatement(into: first, bucket: bucket)
        // 2 度目でも Tide statement は重複しない。
        XCTAssertEqual(tideStatements(try parse(second)).count, 1)
        // sortedKeys 直列化なので、既に Tide statement だけのポリシーは byte 一致まで安定。
        XCTAssertEqual(first, second)
    }

    func testMergeReplacesStaleTideStatement() throws {
        // 既存に古い Tide statement（Resource が別物）が入っていても、最新定義に置換され重複しない。
        let stale = """
        {"Version":"2012-10-17","Statement":[
          {"Sid":"\(BucketPolicyBuilder.tideDenySid)","Effect":"Deny","Principal":"*","Action":"s3:*","Resource":"arn:aws:s3:::old-bucket/*","Condition":{"Bool":{"aws:SecureTransport":"false"}}}
        ]}
        """
        let out = try BucketPolicyBuilder.mergeTLSDenyStatement(into: stale, bucket: bucket)
        let tide = tideStatements(try parse(out))
        XCTAssertEqual(tide.count, 1)
        XCTAssertEqual(try XCTUnwrap(tide.first)["Resource"] as? [String],
                       ["arn:aws:s3:::\(bucket)", "arn:aws:s3:::\(bucket)/*"], "最新の Resource に置換")
    }

    func testMergeHandlesSingleStatementObject() throws {
        // IAM 仕様: Statement は単一オブジェクトでも合法。配列に正規化して両方残す。
        let existing = """
        {"Version":"2012-10-17","Statement":{"Sid":"Solo","Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::\(bucket)/*"}}
        """
        let out = try BucketPolicyBuilder.mergeTLSDenyStatement(into: existing, bucket: bucket)
        let all = statements(try parse(out))
        XCTAssertEqual(all.count, 2)
        XCTAssertTrue(all.contains { ($0["Sid"] as? String) == "Solo" })
    }

    func testMergeThrowsOnUnparseableExisting() {
        XCTAssertThrowsError(try BucketPolicyBuilder.mergeTLSDenyStatement(into: "not-json{", bucket: bucket)) { error in
            guard case BucketPolicyBuilder.BucketPolicyError.unparseableExistingPolicy = error else {
                return XCTFail("expected unparseableExistingPolicy, got \(error)")
            }
        }
    }

    func testMergeThrowsOnMalformedStatement() {
        // Statement が存在するのに配列/オブジェクトでない（不正）→ 黙って捨てず throw して上書きを避ける（nit-4）。
        let bad = #"{"Version":"2012-10-17","Statement":"should-be-array-or-object"}"#
        XCTAssertThrowsError(try BucketPolicyBuilder.mergeTLSDenyStatement(into: bad, bucket: bucket)) { error in
            guard case BucketPolicyBuilder.BucketPolicyError.unparseableExistingPolicy = error else {
                return XCTFail("expected unparseableExistingPolicy, got \(error)")
            }
        }
    }

    func testMergeIntoEmptyStatementArray() throws {
        // 空の Statement 配列は不正ではない（throw しない）。Tide statement を 1 件だけ足す。
        let existing = #"{"Version":"2012-10-17","Statement":[]}"#
        let out = try BucketPolicyBuilder.mergeTLSDenyStatement(into: existing, bucket: bucket)
        XCTAssertEqual(tideStatements(try parse(out)).count, 1)
    }

    // MARK: - 適用済み判定

    func testIsEnforcedFalseWhenNoPolicy() {
        XCTAssertFalse(BucketPolicyBuilder.isTLSDenyEnforced(in: nil, bucket: bucket))
        XCTAssertFalse(BucketPolicyBuilder.isTLSDenyEnforced(in: "", bucket: bucket))
    }

    func testIsEnforcedTrueAfterMerge() throws {
        let out = try BucketPolicyBuilder.mergeTLSDenyStatement(into: nil, bucket: bucket)
        XCTAssertTrue(BucketPolicyBuilder.isTLSDenyEnforced(in: out, bucket: bucket))
    }

    func testIsEnforcedIgnoresKeyOrder() throws {
        // key 順が違っても同内容なら適用済みと判定する（毎起動の無駄な put を避ける本質）。
        let reordered = """
        {"Statement":[{"Action":"s3:*","Condition":{"Bool":{"aws:SecureTransport":"false"}},"Effect":"Deny","Principal":"*","Resource":["arn:aws:s3:::\(bucket)","arn:aws:s3:::\(bucket)/*"],"Sid":"\(BucketPolicyBuilder.tideDenySid)"}],"Version":"2012-10-17"}
        """
        XCTAssertTrue(BucketPolicyBuilder.isTLSDenyEnforced(in: reordered, bucket: bucket))
    }

    func testIsEnforcedFalseForDifferentBucket() throws {
        let out = try BucketPolicyBuilder.mergeTLSDenyStatement(into: nil, bucket: "other-bucket")
        XCTAssertFalse(BucketPolicyBuilder.isTLSDenyEnforced(in: out, bucket: bucket),
                       "Resource が別バケットなら未適用扱い")
    }
}
