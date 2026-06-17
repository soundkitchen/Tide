import XCTest
@testable import Tide

/// `DiagnosticsExporter` の純粋なテキスト組み立てを固定する。
/// 最重要の不変条件: 診断テキストはシークレットを構造的に含まない（入力に認証情報が無い）。
final class DiagnosticsExporterTests: XCTestCase {

    private func sampleInputs(limit: Int64 = -1) -> DiagnosticsExporter.Inputs {
        DiagnosticsExporter.Inputs(
            appVersion: "0.1.0",
            appBuild: "7",
            osVersion: "Version 26.0",
            deviceId: "device-abc",
            bucket: "my-bucket",
            region: "ap-northeast-1",
            syncRootPath: "/Users/me/Sync",
            uploadSizeLimitBytes: limit,
            notificationsEnabled: true,
            queueDepth: 3,
            logCount: 2,
            generatedAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
    }

    func testDiagnosticsTextIncludesKeyFields() {
        let text = DiagnosticsExporter.diagnosticsText(sampleInputs())
        XCTAssertTrue(text.contains("App version: 0.1.0 (build 7)"))
        XCTAssertTrue(text.contains("Bucket: my-bucket"))
        XCTAssertTrue(text.contains("Region: ap-northeast-1"))
        XCTAssertTrue(text.contains("Sync folder: /Users/me/Sync"))
        XCTAssertTrue(text.contains("Upload size limit: No limit"))
        XCTAssertTrue(text.contains("Notifications: enabled"))
        XCTAssertTrue(text.contains("Queue depth: 3"))
        XCTAssertTrue(text.contains("Generated:"))
    }

    /// 認証情報非混入の不変条件: 「含まれない」明記があり、シークレットらしき文字列は出ない
    /// （Inputs にシークレットフィールドが無い＝構造的に漏れない、を実行時にも担保）。
    func testDiagnosticsTextHasNoSecrets() {
        let text = DiagnosticsExporter.diagnosticsText(sampleInputs())
        XCTAssertTrue(text.contains("NOT included"))
        XCTAssertFalse(text.contains("AKIA"))          // AWS アクセスキー ID の典型 prefix
        XCTAssertFalse(text.lowercased().contains("secret"))
    }

    func testUploadLimitFormatting() {
        let text = DiagnosticsExporter.diagnosticsText(sampleInputs(limit: 5 * 1024 * 1024 * 1024))
        XCTAssertTrue(text.contains("Upload size limit: 5 GB"))
    }

    func testLogTextFormatsRecords() {
        let records = [
            SyncLogRecord(id: 2, timestamp: 1_780_000_100, eventType: "upload",
                          path: "Docs/a.txt", message: "Uploaded", details: nil),
            SyncLogRecord(id: 1, timestamp: 1_780_000_000, eventType: "error",
                          path: "Docs/b.txt", message: "Failed", details: "network timeout"),
        ]
        let text = DiagnosticsExporter.logText(records)
        XCTAssertTrue(text.contains("[upload]"))
        XCTAssertTrue(text.contains("Docs/a.txt"))
        XCTAssertTrue(text.contains("Uploaded"))
        XCTAssertTrue(text.contains("[error]"))
        XCTAssertTrue(text.contains("— network timeout"))
    }

    func testLogTextEmpty() {
        XCTAssertEqual(DiagnosticsExporter.logText([]), "(no log entries)\n")
    }
}
