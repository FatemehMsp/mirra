import XCTest
@testable import AndroidMonitorCore

final class PermissionsServiceTests: XCTestCase {
    func testParseRuntimePermissionsWithGrantedState() {
        let dump = """
        declared permissions:
          android.permission.SOME_PERM: granted=true
        runtime permissions:
          android.permission.CAMERA: granted=false, flags=[ USER_SENSITIVE_WHEN_GRANTED]
          android.permission.ACCESS_FINE_LOCATION: granted=true, flags=[ GRANTED_BY_DEFAULT]
        install permissions:
          android.permission.INTERNET: granted=true
          android.permission.WAKE_LOCK: granted=true
        """
        let permissions = PermissionsService.parse(dump)
        XCTAssertEqual(permissions.count, 2)
        XCTAssertEqual(permissions.first?.name, "android.permission.ACCESS_FINE_LOCATION")
        XCTAssertEqual(permissions.first?.granted, true)
        XCTAssertEqual(permissions.last?.name, "android.permission.CAMERA")
        XCTAssertEqual(permissions.last?.granted, false)
    }

    func testParseMergesMultipleRuntimeBlocks() {
        let dump = """
        runtime permissions:
          android.permission.CAMERA: granted=false
        another section:
          something else
        runtime permissions:
          android.permission.CAMERA: granted=true
        """
        let permissions = PermissionsService.parse(dump)
        XCTAssertEqual(permissions.count, 1)
        XCTAssertEqual(permissions.first?.granted, true)
    }

    func testParseEmptyDump() {
        XCTAssertEqual(PermissionsService.parse(""), [])
        XCTAssertEqual(PermissionsService.parse("Package [com.example.app]"), [])
    }
}

final class BugReportServiceTests: XCTestCase {
    func testBugReportErrorMessages() {
        XCTAssertEqual(BugReportService.BugReportError.nothingCollected.localizedDescription, "Nothing could be collected from the device")
        XCTAssertEqual(BugReportService.BugReportError.zipFailed.localizedDescription, "Could not package the report")
    }
}

final class VideoToolsTests: XCTestCase {
    func testVideoToolsErrorMessages() {
        XCTAssertEqual(VideoTools.VideoToolsError.badRange.localizedDescription, "The time range is empty")
        XCTAssertEqual(VideoTools.VideoToolsError.noVideoTrack.localizedDescription, "The file has no video track")
        XCTAssertEqual(VideoTools.VideoToolsError.exportFailed.localizedDescription, "Export failed")
    }
}
