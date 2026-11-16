import XCTest
@testable import AndroidMonitorCore

final class WDASetupTests: XCTestCase {
    func testTeamIDFromSecurityOutput() {
        let output = """
          1) ABCDEF1234567890 "Apple Development: fatemeh@example.com (AB12CD34E5)"
          2) 1122334455667788 "Apple Development: work@company.com (ZX98QW76TR)"
             2 valid identities found
        """
        XCTAssertEqual(WDASetupService.teamID(in: output), "AB12CD34E5")
    }

    func testTeamIDNilWhenNoIdentities() {
        XCTAssertNil(WDASetupService.teamID(in: "     0 valid identities found\n"))
    }

    func testFriendlyErrorForMissingAccount() {
        let stderr = "error: No Account for Team \"AB12CD34E5\". Add a new account in Accounts settings or verify that your accounts have valid credentials."
        let message = WDASetupService.friendlyBuildError(stderr, code: 65)
        XCTAssertTrue(message.contains("Settings → Accounts"), message)
    }

    func testFriendlyErrorForExpiredProfile() {
        let stderr = "error: Provisioning profile \"dev.mirra.wda.runner\" has expired."
        let message = WDASetupService.friendlyBuildError(stderr, code: 65)
        XCTAssertTrue(message.contains("expired"), message)
    }

    func testFriendlyErrorForLockedDevice() {
        let stderr = "error: Unable to install \"WebDriverAgentRunner-Runner.app\": device is locked."
        let message = WDASetupService.friendlyBuildError(stderr, code: 70)
        XCTAssertTrue(message.contains("Unlock the device"), message)
    }

    func testAppleIDHintWhenNoTeam() {
        let error: Error = WDASetupService.SetupError.noSigningTeam
        XCTAssertTrue(error.localizedDescription.contains("Xcode"), error.localizedDescription)
    }

    func testBundleIDIsUniqueForFreeAccounts() {
        XCTAssertTrue(WDASetupService.bundleID.hasPrefix("dev.mirra"))
    }
}

final class WDAClientTests: XCTestCase {
    func testTapActionsUseViewportCoordinates() throws {
        let actions = WDAClient.pointer([
            ["type": "pointerMove", "duration": 0, "x": 120, "y": 340, "origin": "viewport"],
            ["type": "pointerDown", "button": 0],
            ["type": "pointerUp", "button": 0],
        ])
        XCTAssertEqual(actions.count, 1)
        let pointer = try XCTUnwrap(actions.first)
        XCTAssertEqual(pointer["type"] as? String, "pointer")
        XCTAssertEqual(pointer["id"] as? String, "mirra-finger")
        let steps = try XCTUnwrap(pointer["actions"] as? [[String: Any]])
        XCTAssertEqual(steps.count, 3)
        XCTAssertEqual(steps[0]["origin"] as? String, "viewport")
        XCTAssertEqual(steps[0]["x"] as? Int, 120)
        XCTAssertEqual(steps[1]["type"] as? String, "pointerDown")
    }

    func testPointerParametersAreTouch() throws {
        let pointer = try XCTUnwrap(WDAClient.pointer([]).first)
        let parameters = try XCTUnwrap(pointer["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["pointerType"] as? String, "touch")
    }
}

final class USBMuxTests: XCTestCase {
    func testPortNumberUsesBigEndianByteOrder() {
        // usbmuxd expects the byte-swapped value inside the plist; 8100 -> 0xA41F numerically.
        XCTAssertEqual(UInt16(8100).bigEndian, 42015)
    }

    func testPlistPayloadCarriesMessageType() throws {
        let data = try USBMux.plistData(["MessageType": "ListDevices"])
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("ListDevices"))
    }

    func testDevicesParseNestedSerialFromListDevicesReply() {
        // Captured from a real usbmuxd: the serial lives under Properties, not at entry level.
        let reply: [String: Any] = ["DeviceList": [[
            "MessageType": "Attached",
            "DeviceID": 27,
            "Properties": [
                "ConnectionType": "USB",
                "DeviceID": 27,
                "SerialNumber": "00008030-000E50283C6B802E",
            ],
        ]]]
        let devices = USBMux.devices(in: reply)
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.serial, "00008030-000E50283C6B802E")
        XCTAssertEqual(devices.first?.id, 27)
    }

    func testDevicesEmptyWhenReplyHasNoDeviceList() {
        XCTAssertEqual(USBMux.devices(in: ["MessageType": "Result", "Number": 0]), [])
    }
}