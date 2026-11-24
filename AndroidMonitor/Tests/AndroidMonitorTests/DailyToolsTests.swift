import XCTest
@testable import AndroidMonitorCore

final class CrashWatcherTests: XCTestCase {
    func testFatalExceptionCollectsTraceUntilBlankLine() {
        let watcher = CrashWatcher()
        XCTAssertNil(watcher.feed(line: "11-12 15:30:00 E AndroidRuntime: FATAL EXCEPTION: main"))
        XCTAssertNil(watcher.feed(line: "11-12 15:30:00 E AndroidRuntime: java.lang.NullPointerException"))
        XCTAssertNil(watcher.feed(line: "11-12 15:30:00 E AndroidRuntime:   at com.example.MainActivity.onCreate(MainActivity.kt:42)"))
        let event = watcher.feed(line: "11-12 15:30:00 E AndroidRuntime: ")
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.kind, .fatal)
        XCTAssertTrue(event?.trace.contains("NullPointerException") == true)
        XCTAssertTrue(event?.trace.contains("MainActivity.kt:42") == true)
    }

    func testANRPackageIsExtracted() {
        XCTAssertEqual(CrashWatcher.anrPackage(in: "E ActivityManager: ANR in com.example.app"), "com.example.app")
        XCTAssertNil(CrashWatcher.anrPackage(in: "something else"))
    }

    func testTraceLineDetection() {
        XCTAssertTrue(CrashWatcher.isTraceLine("  at com.example.Foo.bar(Foo.java:10)"))
        XCTAssertTrue(CrashWatcher.isTraceLine("Caused by: java.io.IOException"))
        XCTAssertTrue(CrashWatcher.isTraceLine("... 12 more"))
        XCTAssertTrue(CrashWatcher.isTraceLine("java.lang.IllegalStateException"))
        XCTAssertFalse(CrashWatcher.isTraceLine("I ActivityManager: Killing 1234:com.example.app"))
    }

    func testNothingIsEmittedForNormalLogcat() {
        let watcher = CrashWatcher()
        XCTAssertNil(watcher.feed(line: "I ActivityManager: Displayed com.example.app/.MainActivity"))
        XCTAssertNil(watcher.feed(line: "D SomeTag: hello world"))
    }
}

final class AppActionsTests: XCTestCase {
    func testRequestedPermissionsDeduplicatesAndFilters() {
        let dump = """
          requested permissions:
            android.permission.CAMERA
            android.permission.RECORD_AUDIO
            android.permission.INTERNET
          install permissions:
            android.permission.INTERNET: granted=true
            android.permission.CAMERA: granted=false
        """
        let permissions = AppActionsService.requestedPermissions(in: dump)
        XCTAssertEqual(permissions, ["android.permission.CAMERA", "android.permission.RECORD_AUDIO", "android.permission.INTERNET"])
    }

    func testNoPermissionsInEmptyDump() {
        XCTAssertEqual(AppActionsService.requestedPermissions(in: "Package [com.example.app]"), [])
    }
}
