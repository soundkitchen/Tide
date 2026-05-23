import Foundation

struct AWSCredentials: Equatable, Sendable {
    let accessKeyId: String
    let secretAccessKey: String

    var isEmpty: Bool {
        accessKeyId.isEmpty || secretAccessKey.isEmpty
    }
}
