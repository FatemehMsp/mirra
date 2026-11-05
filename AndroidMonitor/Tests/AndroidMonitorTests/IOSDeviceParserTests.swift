import XCTest
@testable import AndroidMonitorCore

final class IOSDeviceParserTests: XCTestCase {
    private func devicesJSON(reality: String, transport: String, tunnel: String) -> Data {
        Data("""
        {"result":{"devices":[{"identifier":"AAAA-1111",
          "hardwareProperties":{"udid":"00008110-0001","reality":"\(reality)","platform":"iOS","marketingName":"iPhone 15 Pro","productType":"iPhone16,1"},
          "deviceProperties":{"name":"Test iPhone","osVersionNumber":"18.3.1"},
          "connectionProperties":{"transportType":"\(transport)","tunnelState":"\(tunnel)"}}]}}
        """.utf8)
    }

    func testPhysicalUSBDeviceIsParsed() {
        let devices = IOSDeviceService.parseDevices(devicesJSON(reality: "physical", transport: "wired", tunnel: "connected"))
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].name, "Test iPhone")
        XCTAssertEqual(devices[0].model, "iPhone 15 Pro")
        XCTAssertEqual(devices[0].udid, "00008110-0001")
        XCTAssertEqual(devices[0].transport, .usb)
        XCTAssertTrue(devices[0].isConnected)
    }

    func testSimulatorsAreIgnored() {
        XCTAssertTrue(IOSDeviceService.parseDevices(devicesJSON(reality: "simulated", transport: "sameMachine", tunnel: "disconnected")).isEmpty)
    }

    func testGarbageYieldsNoDevices() {
        XCTAssertTrue(IOSDeviceService.parseDevices(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(IOSDeviceService.parseApps(Data("{}".utf8)).isEmpty)
    }

    func testAppsAreParsed() {
        let data = Data(#"{"result":{"apps":[{"bundleIdentifier":"com.example.a","name":"A","version":"1.2","removable":true},{"bundleIdentifier":"com.apple.mobilesafari","name":"Safari","removable":false}]}}"#.utf8)
        let apps = IOSDeviceService.parseApps(data)
        XCTAssertEqual(apps.map(\.bundleID), ["com.example.a", "com.apple.mobilesafari"])
        XCTAssertTrue(apps[0].isUserApp)
        XCTAssertFalse(apps[1].isUserApp)
    }
}

final class IOSErrorMessageTests: XCTestCase {
    func testLockedDeviceMessage() {
        let text = "The developer disk image could not be mounted (error 12040)\nThe operation failed because the device was still locked."
        XCTAssertTrue(IOSDeviceService.friendlyMessage(for: text).contains("locked"))
    }

    func testFallsBackToLastLine() {
        XCTAssertEqual(IOSDeviceService.friendlyMessage(for: "first\nsomething odd\n"), "something odd")
    }
}
