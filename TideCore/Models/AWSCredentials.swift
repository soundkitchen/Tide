import Foundation

public struct AWSCredentials: Equatable, Sendable {
    public let accessKeyId: String
    public let secretAccessKey: String

    public init(accessKeyId: String, secretAccessKey: String) {
        self.accessKeyId = accessKeyId
        self.secretAccessKey = secretAccessKey
    }

    public var isEmpty: Bool {
        accessKeyId.isEmpty || secretAccessKey.isEmpty
    }
}
