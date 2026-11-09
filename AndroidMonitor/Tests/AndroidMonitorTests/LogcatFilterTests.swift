import XCTest
@testable import AndroidMonitorCore

final class LogcatFilterTests: XCTestCase {
    private func entry(_ tag: String, _ message: String, _ priority: LogPriority = .debug, pid: Int = 100) -> LogcatEntry {
        LogcatEntry(timestamp: 0, pid: pid, tid: pid, priority: priority, tag: tag, message: message)
    }

    func testEmptyQueryMatchesEverything() {
        XCTAssertTrue(LogcatFilter("").matches(entry("A", "b"), packageName: nil))
    }

    func testPackageAndTag() {
        let f = LogcatFilter("package:com.example tag:OkHttp")
        XCTAssertTrue(f.matches(entry("OkHttp", "GET /"), packageName: "com.example.app"))
        XCTAssertFalse(f.matches(entry("OkHttp", "GET /"), packageName: "com.other"))
        XCTAssertFalse(f.matches(entry("Retrofit", "GET /"), packageName: "com.example.app"))
    }

    func testSameKeyIsOrDifferentKeysAreAnd() {
        let f = LogcatFilter("tag:OkHttp tag:Retrofit level:warn")
        XCTAssertTrue(f.matches(entry("Retrofit", "x", .error), packageName: nil))
        XCTAssertFalse(f.matches(entry("Retrofit", "x", .debug), packageName: nil))
        XCTAssertFalse(f.matches(entry("Glide", "x", .error), packageName: nil))
    }

    func testNegationExactRegexAndFreeText() {
        XCTAssertFalse(LogcatFilter("-tag:Choreographer").matches(entry("Choreographer", "skipped"), packageName: nil))
        XCTAssertFalse(LogcatFilter("tag=:Ok").matches(entry("OkHttp", ""), packageName: nil))
        XCTAssertTrue(LogcatFilter("tag~:^Ok.*p$").matches(entry("OkHttp", ""), packageName: nil))
        XCTAssertTrue(LogcatFilter("timeout").matches(entry("Net", "SocketTimeout"), packageName: nil))
    }

    func testCrashAndLevelParsing() {
        XCTAssertTrue(LogcatFilter("is:crash").matches(entry("AndroidRuntime", "FATAL EXCEPTION", .error), packageName: nil))
        XCTAssertFalse(LogcatFilter("is:crash").matches(entry("Net", "oops", .error), packageName: nil))
        XCTAssertEqual(LogcatFilter("level:w").minimumLevel, .warning)
    }

    func testProcessTable() {
        let table = ProcessTableParser.parse("  PID NAME\n    1 init\n 4182 com.example.notes\n 4190 com.example.notes:remote\n")
        XCTAssertEqual(table[4182], "com.example.notes")
        XCTAssertEqual(table[4190], "com.example.notes:remote")
        XCTAssertNil(table[0])
    }
}
