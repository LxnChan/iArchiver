import XCTest
@testable import IArchiverKit

final class ArchiveEngineTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "zip", subdirectory: "Fixtures"))
    }
    func testAllWritableFormatsRoundTripThroughSwiftBoundary() async throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("中文😀.txt")
        let payload = Data("A real Swift-to-C-to-C++ round trip.\n".utf8)
        try payload.write(to: source)
        for format in ArchiveFormat.writable {
            let engine = LibarchiveEngine()
            let archive = try await engine.create(sources: [source], name: "Archive", format: format)
            defer { ArchiveWorkspace.removeStage(containing: archive) }
            let snapshot = try await engine.list(urls: [archive])
            let stage = try await engine.extract(snapshot)
            defer { ArchiveWorkspace.removeStage(containing: stage) }
            let files = try FileManager.default.contentsOfDirectory(at: stage, includingPropertiesForKeys: nil)
            XCTAssertEqual(files.count, 1, format.rawValue)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(files.first)), payload, format.rawValue)
        }
    }
    func testAESZIPAndSevenZipPasswords() async throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("秘密.txt")
        try Data("secret".utf8).write(to: source)
        for format: ArchiveFormat in [.zip, .sevenZip] {
            let engine = LibarchiveEngine()
            let archive = try await engine.create(sources: [source], name: "Encrypted", format: format, password: "密码😀")
            defer { ArchiveWorkspace.removeStage(containing: archive) }
            let snapshot = try await engine.list(urls: [archive], password: "密码😀")
            let stage = try await engine.extract(snapshot, password: "密码😀")
            ArchiveWorkspace.removeStage(containing: stage)
            do {
                _ = try await engine.extract(snapshot, password: "wrong")
                XCTFail("Wrong password was accepted")
            } catch { XCTAssertTrue(error is ArchiveFailure) }
        }
    }
    func testLegacyFilenameOverrideAndAutomaticChineseDetection() async throws {
        let url = try fixture("legacy-gb18030")
        XCTAssertEqual(FilenameDetector.suggest(for: url, preferredLanguage: "zh-Hans").encoding, .gb18030)
        let snapshot = try await LibarchiveEngine().list(urls: [url], encoding: .gb18030)
        XCTAssertEqual(snapshot.entries.map(\.path), ["资料/简体中文.txt"])
    }
    func testTraditionalAndJapaneseNamesDecodeWithoutReplacementCharacters() async throws {
        for (name, encoding, expected) in [("legacy-big5", FilenameEncoding.big5, "檔案/繁體中文.txt"),
                                           ("legacy-cp932", FilenameEncoding.shiftJIS, "資料/テスト.txt"),
                                           ("legacy-cp437", FilenameEncoding.cp437, "café.txt")] {
            let snapshot = try await LibarchiveEngine().list(urls: [fixture(name)], encoding: encoding)
            XCTAssertEqual(snapshot.entries.map(\.path), [expected])
        }
    }
    func testUnicodeMetadataWinsOnlyWithValidRawNameCRC() async throws {
        let valid = try fixture("unicode-extra")
        XCTAssertEqual(FilenameDetector.samples(for: valid, encoding: .big5), ["标准名称😀.txt"])
        let snapshot = try await LibarchiveEngine().list(urls: [valid], encoding: .gb18030)
        XCTAssertEqual(snapshot.entries.map(\.path), ["标准名称😀.txt"])
        let invalid = try fixture("unicode-extra-invalid")
        XCTAssertEqual(FilenameDetector.samples(for: invalid, encoding: .gb18030), ["资料/简体中文.txt"])
    }
    func testUnsafeArchiveCannotWriteOutsideStage() async throws {
        for name in ["traversal", "case-collision", "unicode-collision", "link", "file-parent"] {
            let engine = LibarchiveEngine()
            let snapshot = try await engine.list(urls: [fixture(name)])
            do { _ = try await engine.extract(snapshot); XCTFail("Unsafe fixture accepted: \(name)") }
            catch let failure as ArchiveFailure { XCTAssertEqual(failure.reason, .unsafePath, name) }
        }
    }
    func testPreviewLimitAndSelectedEntryExtraction() async throws {
        let engine = LibarchiveEngine()
        let snapshot = try await engine.list(urls: [fixture("selection")])
        let chosen = try XCTUnwrap(snapshot.entries.first { $0.path == "small.txt" })
        let stage = try await engine.extract(snapshot, selection: [chosen.id], preview: true)
        defer { ArchiveWorkspace.removeStage(containing: stage) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: stage.path), ["small.txt"])
        var limits = ArchiveLimits(); limits.previewBytes = 3
        do { _ = try await LibarchiveEngine(limits: limits).extract(snapshot, selection: [chosen.id], preview: true); XCTFail() }
        catch let failure as ArchiveFailure { XCTAssertEqual(failure.reason, .limit) }
    }
    func testChangedArchiveIsRejectedBeforeExtraction() async throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("changed.zip")
        try FileManager.default.copyItem(at: fixture("selection"), to: url)
        let engine = LibarchiveEngine()
        let snapshot = try await engine.list(urls: [url])
        try Data("changed".utf8).write(to: url)
        do { _ = try await engine.extract(snapshot); XCTFail() }
        catch let failure as ArchiveFailure { XCTAssertEqual(failure.reason, .changed) }
    }
    func testPrecancelledJobNeverCompletesSuccessfully() async throws {
        let control = JobControl(); control.cancel()
        do { _ = try await LibarchiveEngine().list(urls: [fixture("selection")], control: control); XCTFail() }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testLegacyArchiveRepackUsesStandardUnicodeNames() async throws {
        let engine = LibarchiveEngine()
        let original = try fixture("legacy-gb18030")
        let originalData = try Data(contentsOf: original)
        let snapshot = try await engine.list(urls: [original], encoding: .gb18030)
        let rewritten = try await engine.repack(snapshot, name: "Compatible")
        defer { ArchiveWorkspace.removeStage(containing: rewritten) }
        let standard = try await engine.list(urls: [rewritten], encoding: .utf8)
        XCTAssertTrue(standard.entries.contains { $0.path == "资料/简体中文.txt" })
        XCTAssertEqual(try Data(contentsOf: original), originalData)
    }
    func testExclusiveCreationCannotTruncateAnExistingFile() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("existing.txt")
        let original = Data("original".utf8)
        try original.write(to: url)
        XCTAssertThrowsError(try ArchiveWorkspace.createExclusiveFile(at: url))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
}
