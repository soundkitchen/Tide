import XCTest
import AppKit
@testable import Tide

/// About ウィンドウのアプリアイコンは `NSImage(named: "AppIcon")`（バンドルのコンパイル済み
/// asset catalog）を一次ソースにする。テストホストが Tide.app なので、これは本番表示と同じ
/// main bundle の asset catalog を引く＝アセット名の不一致・appiconset の取り出し不可を検知できる
/// （`MenuBarPresentationTests.testMenuBarIconAssetsExist` と同じ「無言の空画像」防止）。
final class AboutWindowTests: XCTestCase {
    func testAppIconAssetResolves() {
        XCTAssertNotNil(
            NSImage(named: "AppIcon"),
            "About のアプリアイコン（appiconset 'AppIcon'）が NSImage(named:) で解決できない"
        )
    }
}
