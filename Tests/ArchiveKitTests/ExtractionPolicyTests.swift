import XCTest
@testable import IArchiverKit

final class ExtractionPolicyTests: XCTestCase {
    private func entry(_ path: String, kind: ArchiveEntry.Kind = .file) -> ArchiveEntry {
        ArchiveEntry(id: 0, path: path, size: 1, modified: .distantPast, kind: kind, isEncrypted: false)
    }
    func testNormalizationPreservesNamesAndAcceptsWindowsSeparators() throws {
        XCTAssertEqual(try ExtractionPolicy.normalized("./资料\\😀.txt"), "资料/😀.txt")
    }
    func testTraversalAbsoluteAndControlPathsAreBlocked() {
        for path in ["../escape", "/tmp/x", "C:\\temp\\x", "a/../b", "a\0b", "a\nb", "a//b", "a/./b"] {
            XCTAssertThrowsError(try ExtractionPolicy.normalized(path), path)
        }
    }
    func testCaseAliasesCannotMergeTrees() throws {
        var policy = ExtractionPolicy()
        _ = try policy.reserve(entry("A/one"))
        XCTAssertThrowsError(try policy.reserve(entry("a/two")))
    }
    func testUnicodeAliasesCannotOverwrite() throws {
        var policy = ExtractionPolicy()
        _ = try policy.reserve(entry("café.txt"))
        XCTAssertThrowsError(try policy.reserve(entry("cafe\u{301}.txt")))
    }
    func testImplicitThenExplicitDirectoryIsAllowed() throws {
        var policy = ExtractionPolicy()
        _ = try policy.reserve(entry("folder/file"))
        _ = try policy.reserve(entry("folder", kind: .directory))
        XCTAssertThrowsError(try policy.reserve(entry("folder", kind: .directory)))
    }
    func testUnicodeDirectoryAliasesCannotMergeSeparateTrees() throws {
        var policy = ExtractionPolicy()
        _ = try policy.reserve(entry("café/one"))
        XCTAssertThrowsError(try policy.reserve(entry("cafe\u{301}/two")))
    }
    func testFileCannotBecomeAParentDirectory() throws {
        var policy = ExtractionPolicy()
        _ = try policy.reserve(entry("parent"))
        XCTAssertThrowsError(try policy.reserve(entry("parent/child")))
    }
    func testLinksAndSpecialFilesAreBlocked() {
        for kind: ArchiveEntry.Kind in [.link, .special] {
            var policy = ExtractionPolicy()
            XCTAssertThrowsError(try policy.reserve(entry("link", kind: kind)))
        }
    }
    func testDestinationStaysInsideRoot() throws {
        let root = URL(fileURLWithPath: "/tmp/stage", isDirectory: true)
        XCTAssertEqual(try ExtractionPolicy.destination(root: root, relative: "folder/file").path, "/tmp/stage/folder/file")
        XCTAssertThrowsError(try ExtractionPolicy.destination(root: root, relative: "../elsewhere"))
    }
}
