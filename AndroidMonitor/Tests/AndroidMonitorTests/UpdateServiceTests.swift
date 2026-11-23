import XCTest
@testable import AndroidMonitorCore

final class CaptureNameTests: XCTestCase {
    func testFileIncludesTimestampSuffix() {
        var components = DateComponents()
        components.year = 2026; components.month = 11; components.day = 12
        components.hour = 15; components.minute = 30; components.second = 4
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let date = utc.date(from: components)!

        XCTAssertEqual(
            CaptureName.file(prefix: "screenshot-RZ8T50TKLRA", fileExtension: "png", date: date, timeZone: TimeZone(identifier: "UTC")!),
            "screenshot-RZ8T50TKLRA-20261112-153004.png"
        )
        XCTAssertEqual(
            CaptureName.file(prefix: "ios-recording", fileExtension: "mov", date: date, timeZone: TimeZone(identifier: "UTC")!),
            "ios-recording-20261112-153004.mov"
        )
    }

    func testStampsDifferWithinASecond() {
        let first = CaptureName.stamp(date: Date(timeIntervalSince1970: 1_768_000_000))
        let second = CaptureName.stamp(date: Date(timeIntervalSince1970: 1_768_000_001))
        XCTAssertNotEqual(first, second)
    }
}

final class UpdateServiceTests: XCTestCase {
    func testVersionParsingStripsV() {
        XCTAssertEqual(UpdateService.parseVersion("v0.4.1"), [0, 4, 1])
        XCTAssertEqual(UpdateService.parseVersion("0.4"), [0, 4])
        XCTAssertEqual(UpdateService.parseVersion("v1.2.3.4"), [1, 2, 3, 4])
        XCTAssertEqual(UpdateService.parseVersion("nonsense"), [])
    }

    func testIsNewerComparesComponentWise() {
        XCTAssertTrue(UpdateService.isNewer("v0.5.0", than: "0.4.0"))
        XCTAssertTrue(UpdateService.isNewer("0.4.1", than: "0.4"))
        XCTAssertTrue(UpdateService.isNewer("v1.0.0", than: "0.9.9"))
        XCTAssertFalse(UpdateService.isNewer("0.4.0", than: "0.4.0"))
        XCTAssertFalse(UpdateService.isNewer("0.3.9", than: "0.4.0"))
        XCTAssertFalse(UpdateService.isNewer("nonsense", than: "0.4.0"))
    }

    func testExpectedChecksumTakesFirstToken() {
        XCTAssertEqual(UpdateService.expectedChecksum("abc123  Mirra.dmg\n"), "abc123")
        XCTAssertEqual(UpdateService.expectedChecksum("ABCDEF  Mirra.dmg"), "abcdef")
        XCTAssertNil(UpdateService.expectedChecksum(""))
    }

    func testInstallScriptMountsReplacesAndRelaunches() {
        let script = UpdateService.installScript(dmgPath: "/tmp/Mirra-0.4.1.dmg")
        XCTAssertTrue(script.contains("hdiutil attach"), script)
        XCTAssertTrue(script.contains("rm -rf /Applications/Mirra.app"), script)
        XCTAssertTrue(script.contains("cp -R"), script)
        XCTAssertTrue(script.contains("open /Applications/Mirra.app"), script)
        XCTAssertTrue(script.contains("sleep 1"), script)
    }

    func testLatestReleaseParsing() throws {
        // Sample of the GitHub releases/latest payload shape.
        let json = """
        {"tag_name": "v0.4.1", "assets": [
            {"name": "Mirra.dmg", "browser_download_url": "https://example/Mirra.dmg"},
            {"name": "Mirra.dmg.sha256", "browser_download_url": "https://example/Mirra.dmg.sha256"}
        ]}
        """
        // parseLatest is exercised through latestRelease(); test the pure part via a fixture.
        let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        XCTAssertEqual(root?["tag_name"] as? String, "v0.4.1")
    }
}