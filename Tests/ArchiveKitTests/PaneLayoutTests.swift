import XCTest
import CoreGraphics
@testable import IArchiverKit

final class PaneLayoutTests: XCTestCase {
    func testCompactWindowGivesAllSpaceToFiles() {
        let result = PaneLayout.frames(size: CGSize(width: 390, height: 700), showPreview: true)
        XCTAssertNil(result.preview)
        XCTAssertEqual(result.files.width, 390)
    }
    func testWideWindowPlacesPreviewToLeftOfFiles() throws {
        let result = PaneLayout.frames(size: CGSize(width: 1024, height: 700), showPreview: true)
        let preview = try XCTUnwrap(result.preview)
        XCTAssertEqual(preview.minX, 0)
        XCTAssertLessThan(preview.maxX, result.files.minX)
        XCTAssertEqual(result.files.maxX, 1024)
    }
    func testDuoVerticalDivisionContainsNoContent() throws {
        let division = CGRect(x: 490, y: 0, width: 44, height: 700)
        let result = PaneLayout.frames(size: CGSize(width: 1024, height: 700), showPreview: true, division: division)
        XCTAssertFalse(try XCTUnwrap(result.preview).intersects(division))
        XCTAssertFalse(result.files.intersects(division))
        XCTAssertEqual(result.files.minX, 534)
    }
    func testTabletopDivisionKeepsBothPanelsReachable() throws {
        let division = CGRect(x: 0, y: 360, width: 900, height: 50)
        let result = PaneLayout.frames(size: CGSize(width: 900, height: 800), showPreview: true, division: division)
        XCTAssertEqual(try XCTUnwrap(result.preview).maxY, 360)
        XCTAssertEqual(result.files.minY, 410)
    }
    func testHiddenPreviewRestoresFullFileList() {
        XCTAssertNil(PaneLayout.frames(size: CGSize(width: 1200, height: 800), showPreview: false).preview)
    }
    func testCameraOcclusionDoesNotCoverPreviewControls() throws {
        let camera = CGRect(x: 20, y: 20, width: 48, height: 48)
        let initial = PaneLayout.frames(size: CGSize(width: 1024, height: 700), showPreview: true)
        let safe = PaneLayout.avoidingOcclusions(initial, regions: [camera])
        XCTAssertFalse(try XCTUnwrap(safe.preview).intersects(camera))
        XCTAssertEqual(safe.files, initial.files)
    }
}
