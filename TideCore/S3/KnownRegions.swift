import Foundation

/// バケット作成時に提示する AWS S3 リージョン一覧。
/// 中国 (cn-*) と GovCloud (us-gov-*) は除外。
public enum KnownRegions {
    public struct Region: Identifiable, Hashable, Sendable {
        public let code: String
        public let displayName: String
        public var id: String { code }

        public init(code: String, displayName: String) {
            self.code = code
            self.displayName = displayName
        }
    }

    /// 表示順は地域グループでまとめている。
    public static let all: [Region] = [
        // Americas
        Region(code: "us-east-1", displayName: "US East (N. Virginia)"),
        Region(code: "us-east-2", displayName: "US East (Ohio)"),
        Region(code: "us-west-1", displayName: "US West (N. California)"),
        Region(code: "us-west-2", displayName: "US West (Oregon)"),
        Region(code: "ca-central-1", displayName: "Canada (Central)"),
        Region(code: "ca-west-1", displayName: "Canada (Calgary)"),
        Region(code: "sa-east-1", displayName: "South America (São Paulo)"),

        // Asia Pacific
        Region(code: "ap-northeast-1", displayName: "Asia Pacific (Tokyo)"),
        Region(code: "ap-northeast-2", displayName: "Asia Pacific (Seoul)"),
        Region(code: "ap-northeast-3", displayName: "Asia Pacific (Osaka)"),
        Region(code: "ap-east-1", displayName: "Asia Pacific (Hong Kong)"),
        Region(code: "ap-southeast-1", displayName: "Asia Pacific (Singapore)"),
        Region(code: "ap-southeast-2", displayName: "Asia Pacific (Sydney)"),
        Region(code: "ap-southeast-3", displayName: "Asia Pacific (Jakarta)"),
        Region(code: "ap-southeast-4", displayName: "Asia Pacific (Melbourne)"),
        Region(code: "ap-south-1", displayName: "Asia Pacific (Mumbai)"),
        Region(code: "ap-south-2", displayName: "Asia Pacific (Hyderabad)"),

        // Europe
        Region(code: "eu-west-1", displayName: "Europe (Ireland)"),
        Region(code: "eu-west-2", displayName: "Europe (London)"),
        Region(code: "eu-west-3", displayName: "Europe (Paris)"),
        Region(code: "eu-central-1", displayName: "Europe (Frankfurt)"),
        Region(code: "eu-central-2", displayName: "Europe (Zurich)"),
        Region(code: "eu-north-1", displayName: "Europe (Stockholm)"),
        Region(code: "eu-south-1", displayName: "Europe (Milan)"),
        Region(code: "eu-south-2", displayName: "Europe (Spain)"),

        // Middle East & Africa
        Region(code: "me-south-1", displayName: "Middle East (Bahrain)"),
        Region(code: "me-central-1", displayName: "Middle East (UAE)"),
        Region(code: "il-central-1", displayName: "Israel (Tel Aviv)"),
        Region(code: "af-south-1", displayName: "Africa (Cape Town)")
    ]

    /// コード単位で逆引き。
    public static func displayName(for code: String) -> String {
        all.first(where: { $0.code == code })?.displayName ?? code
    }
}
