import XCTest
import TideCore
@testable import Tide

final class HardcodedIgnoreRulesTests: XCTestCase {
    func testExactNamesExcluded() {
        for name in [".DS_Store", "Thumbs.db", ".fseventsd"] {
            XCTAssertTrue(HardcodedIgnoreRules.shouldIgnore(relativePath: name))
            XCTAssertTrue(HardcodedIgnoreRules.shouldIgnore(relativePath: "sub/\(name)"))
            XCTAssertTrue(HardcodedIgnoreRules.shouldIgnore(relativePath: "a/b/c/\(name)"))
        }
    }

    func testAppleDoublePrefixExcluded() {
        XCTAssertTrue(HardcodedIgnoreRules.shouldIgnore(relativePath: "._foo"))
        XCTAssertTrue(HardcodedIgnoreRules.shouldIgnore(relativePath: "dir/._foo"))
    }

    func testRegularPathsKept() {
        XCTAssertFalse(HardcodedIgnoreRules.shouldIgnore(relativePath: "Documents/report.pdf"))
        XCTAssertFalse(HardcodedIgnoreRules.shouldIgnore(relativePath: ".git/HEAD"))
        XCTAssertFalse(HardcodedIgnoreRules.shouldIgnore(relativePath: ".gitignore"))
        XCTAssertFalse(HardcodedIgnoreRules.shouldIgnore(relativePath: "Photos/IMG.jpg"))
    }

    func testSensitiveDotfilesExcluded() {
        for name in [".env", ".envrc", ".netrc", ".npmrc", ".pgpass"] {
            XCTAssertTrue(HardcodedIgnoreRules.shouldIgnore(relativePath: name), "\(name) should be ignored")
            XCTAssertTrue(HardcodedIgnoreRules.shouldIgnore(relativePath: "sub/\(name)"))
        }
    }

    func testEnvVariantsExcluded() {
        XCTAssertTrue(HardcodedIgnoreRules.shouldIgnore(relativePath: ".env.local"))
        XCTAssertTrue(HardcodedIgnoreRules.shouldIgnore(relativePath: ".env.production"))
        XCTAssertTrue(HardcodedIgnoreRules.shouldIgnore(relativePath: ".env.development.local"))
    }

    func testSensitiveDirectoriesExcluded() {
        // .aws / .ssh / .gnupg / .kube etc.
        for dir in [".aws", ".ssh", ".gnupg", ".kube", ".docker"] {
            XCTAssertTrue(HardcodedIgnoreRules.shouldIgnore(relativePath: dir))
            XCTAssertTrue(HardcodedIgnoreRules.shouldIgnore(relativePath: "\(dir)/credentials"))
            XCTAssertTrue(HardcodedIgnoreRules.shouldIgnore(relativePath: "home/\(dir)/config"))
        }
    }

    func testKeyFilesExcluded() {
        XCTAssertTrue(HardcodedIgnoreRules.shouldIgnore(relativePath: "id_rsa"))
        XCTAssertTrue(HardcodedIgnoreRules.shouldIgnore(relativePath: "id_ed25519"))
        XCTAssertTrue(HardcodedIgnoreRules.shouldIgnore(relativePath: "Documents/id_rsa"))
    }

    func testSuffixPatternsExcluded() {
        XCTAssertTrue(HardcodedIgnoreRules.shouldIgnore(relativePath: "server.pem"))
        XCTAssertTrue(HardcodedIgnoreRules.shouldIgnore(relativePath: "certs/wildcard.key"))
        XCTAssertTrue(HardcodedIgnoreRules.shouldIgnore(relativePath: "store.p12"))
        XCTAssertTrue(HardcodedIgnoreRules.shouldIgnore(relativePath: "app.keystore"))
    }

    // MARK: - 大文字小文字を区別しない（#136）

    func testSuffixPatternsIgnoreCase() {
        for name in ["Server.PEM", "certs/Wildcard.Key", "STORE.P12", "id.PFX", "App.KeyStore"] {
            XCTAssertTrue(HardcodedIgnoreRules.shouldIgnore(relativePath: name), "\(name) should be ignored")
        }
    }

    func testExactNamesIgnoreCase() {
        for name in [".ENV", ".Envrc", "ID_RSA", "Id_Ed25519", "Credentials", ".ds_store", "THUMBS.DB"] {
            XCTAssertTrue(HardcodedIgnoreRules.shouldIgnore(relativePath: name), "\(name) should be ignored")
            XCTAssertTrue(HardcodedIgnoreRules.shouldIgnore(relativePath: "sub/\(name)"))
        }
    }

    func testSensitiveDirectoriesIgnoreCase() {
        for dir in [".SSH", ".Aws", ".GNUPG", ".Config"] {
            XCTAssertTrue(HardcodedIgnoreRules.shouldIgnore(relativePath: dir))
            XCTAssertTrue(HardcodedIgnoreRules.shouldIgnore(relativePath: "home/\(dir)/config"))
        }
    }

    func testPrefixPatternsIgnoreCase() {
        XCTAssertTrue(HardcodedIgnoreRules.shouldIgnore(relativePath: ".ENV.Local"))
        XCTAssertTrue(HardcodedIgnoreRules.shouldIgnore(relativePath: ".documentrevisions-v100"))
        XCTAssertTrue(HardcodedIgnoreRules.shouldIgnore(relativePath: "dir/.TIDE/tmp"))
    }

    func testRegularPathsKeptRegardlessOfCase() {
        XCTAssertFalse(HardcodedIgnoreRules.shouldIgnore(relativePath: "Documents/Report.PDF"))
        XCTAssertFalse(HardcodedIgnoreRules.shouldIgnore(relativePath: ".GITIGNORE"))
        XCTAssertFalse(HardcodedIgnoreRules.shouldIgnore(relativePath: "Environment/notes.txt"))
        XCTAssertFalse(HardcodedIgnoreRules.shouldIgnore(relativePath: "Keys/readme.md"))
    }
}
