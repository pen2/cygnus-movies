import Foundation
import XCTest

final class ContextMenuTests: XCTestCase {
    func testEditorContextMenusUseNativeHighlighting() throws {
        // SwiftUI materializes menu rows only while tracking a live mouse event.
        // Catch new call sites that accidentally inherit the editor's hover style.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var nativeCallCount = 0
        for case let file as URL in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            let pattern = #"\.\s*contextMenu\s*[({]"#
            let matches = try NSRegularExpression(pattern: pattern).numberOfMatches(
                in: source, range: NSRange(source.startIndex..., in: source))
            if file.lastPathComponent == "HoverFeedback.swift" {
                nativeCallCount += matches
                XCTAssertNotNil(source.range(of: #"\.contextMenu\(menuItems: items\)\s*\.buttonStyle\(\.automatic\)"#,
                                             options: .regularExpression))
            } else {
                XCTAssertEqual(matches, 0, "Use editorContextMenu in " + file.lastPathComponent)
            }
        }
        XCTAssertEqual(nativeCallCount, 1)
    }
}
