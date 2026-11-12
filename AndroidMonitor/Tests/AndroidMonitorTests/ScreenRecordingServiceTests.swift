import XCTest
@testable import AndroidMonitorCore

final class TouchEventParserTests: XCTestCase {
    /// Real `getevent -l -t` lines from a Samsung A32 (sec_touchscreen, panel 0…4095).
    private func parser() -> TouchEventParser {
        TouchEventParser(
            config: .init(panelMaxX: 4095, panelMaxY: 4095, screenWidth: 1080, screenHeight: 2400),
            bootOffset: 0
        )
    }

    func testShortPressBecomesTapAtScaledPosition() {
        let parser = parser()
        let lines = """
        [  123528.190172] EV_ABS       ABS_MT_TRACKING_ID   00000e1f
        [  123528.190172] EV_ABS       ABS_MT_POSITION_X    000008ba
        [  123528.190172] EV_ABS       ABS_MT_POSITION_Y    00000923
        [  123528.190172] EV_SYN       SYN_REPORT           00000000
        [  123528.245803] EV_ABS       ABS_MT_POSITION_X    000008bd
        [  123528.245803] EV_SYN       SYN_REPORT           00000000
        [  123528.300000] EV_ABS       ABS_MT_TRACKING_ID   ffffffff
        [  123528.300000] EV_SYN       SYN_REPORT           00000000
        """
        let events = lines.split(separator: "\n").flatMap { parser.parse(line: String($0)) }
        XCTAssertEqual(events.count, 1)
        guard case .tap(let x, let y) = events[0].kind else { return XCTFail("expected tap") }
        // 0x8ba=2234, 0x923=2339 → panel 4095 → screen 1080x2400
        XCTAssertEqual(x, 2234.0 / 4095.0 * 1080.0, accuracy: 1)
        XCTAssertEqual(y, 2339.0 / 4095.0 * 2400.0, accuracy: 1)
        XCTAssertEqual(events[0].timestamp.timeIntervalSince1970, 123528.3, accuracy: 0.01)
    }

    func testLongDragBecomesSwipe() {
        let parser = parser()
        let lines = """
        [  100.000000] EV_ABS       ABS_MT_TRACKING_ID   00000001
        [  100.000000] EV_ABS       ABS_MT_POSITION_X    00000100
        [  100.000000] EV_ABS       ABS_MT_POSITION_Y    00000100
        [  100.000000] EV_SYN       SYN_REPORT           00000000
        [  100.100000] EV_ABS       ABS_MT_POSITION_X    00000800
        [  100.100000] EV_ABS       ABS_MT_POSITION_Y    00000800
        [  100.100000] EV_SYN       SYN_REPORT           00000000
        [  100.200000] EV_ABS       ABS_MT_TRACKING_ID   ffffffff
        [  100.200000] EV_SYN       SYN_REPORT           00000000
        """
        let events = lines.split(separator: "\n").flatMap { parser.parse(line: String($0)) }
        XCTAssertEqual(events.count, 1)
        guard case .swipe(let points) = events[0].kind else { return XCTFail("expected swipe") }
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points.first!.x, 256.0 / 4095.0 * 1080.0, accuracy: 1)
    }

    func testIgnoresCarriageReturnsFromPty() {
        let parser = parser()
        let events = parser.parse(chunk: "[  1.000000] EV_ABS       ABS_MT_TRACKING_ID   00000001\r\n[  1.000000] EV_ABS       ABS_MT_POSITION_X    00000800\r\n[  1.000000] EV_ABS       ABS_MT_POSITION_Y    00000800\r\n[  1.000000] EV_SYN       SYN_REPORT           00000000\r\n[  1.100000] EV_ABS       ABS_MT_TRACKING_ID   ffffffff\r\n[  1.100000] EV_SYN       SYN_REPORT           00000000\r\n")
        XCTAssertEqual(events.count, 1)
    }

    func testFindsTouchscreenInRealDeviceListing() {
        let listing = """
        add device 1: /dev/input/event4
          name:     "grip_notifier"
          events:
            REL (0002): REL_X
        add device 10: /dev/input/event7
          name:     "sec_touchscreen"
          events:
            KEY (0001): KEY_WAKEUP            BTN_TOUCH
            ABS (0003): ABS_X                 : value 0, min 0, max 4095, fuzz 0, flat 0, resolution 0
                        ABS_MT_SLOT           : value 0, min 0, max 9, fuzz 0, flat 0, resolution 0
                        ABS_MT_POSITION_X     : value 0, min 0, max 4095, fuzz 0, flat 0, resolution 0
                        ABS_MT_POSITION_Y     : value 0, min 0, max 4095, fuzz 0, flat 0, resolution 0
                        ABS_MT_TRACKING_ID    : value 0, min 0, max 65535, fuzz 0, flat 0, resolution 0
          input props:
            INPUT_PROP_DIRECT
        """
        let found = TouchEventParser.touchscreen(in: listing)
        XCTAssertEqual(found?.path, "/dev/input/event7")
        XCTAssertEqual(found?.maxX, 4095)
        XCTAssertEqual(found?.maxY, 4095)
    }

    func testParsesScreenSize() {
        XCTAssertEqual(TouchEventParser.screenSize(in: "Physical size: 1080x2400\n")?.width, 1080)
        XCTAssertEqual(TouchEventParser.screenSize(in: "Physical size: 1080x2400\nOverride size: 720x1600\n")?.height, 1600)
        XCTAssertNil(TouchEventParser.screenSize(in: ""))
    }

    func testMonotonicSeconds() {
        let seconds = TouchEventParser.monotonicSeconds(in: "[  123528.190172] EV_ABS ABS_MT_POSITION_X 000008ba")
        XCTAssertNotNil(seconds)
        XCTAssertEqual(seconds ?? 0, 123528.190172, accuracy: 0.000001)
        XCTAssertNil(TouchEventParser.monotonicSeconds(in: "EV_ABS ABS_MT_POSITION_X 000008ba"))
    }
}

final class ScreenRecordingServiceTests: XCTestCase {
    func testScreenRecordPidsParsesPsOutput() {
        let ps = """
        UID          PID    PPID  C STIME TTY      TIME CMD
        shell        22805   7456  2 15:48:59 ?    00:00:01 screenrecord --time-limit 179 /sdcard/mirra-rec-abc123.seg0.mp4
        shell        23145   7456  0 15:49:40 pts/0 00:00:00 sh -c screenrecord --time-limit 179 /sdcard/mirra-rec-abc123.seg0.mp4
        shell        23147   7456  2 15:49:41 pts/0 00:00:00 screenrecord --output-format=h264 -
        """
        XCTAssertEqual(ScreenRecordingService.screenRecordPids(in: ps, matching: "mirra-rec-abc123.seg0.mp4"), [22805])
    }

    func testScreenRecordPidsIgnoreGrepLines() {
        let ps = "shell 1234 1 0 12:00:00 ? 00:00:00 grep mirra-rec-abc.seg0.mp4"
        XCTAssertEqual(ScreenRecordingService.screenRecordPids(in: ps, matching: "mirra-rec-abc.seg0.mp4"), [])
    }

    func testScreenRecordPidsHandleSamsungColumnPadding() {
        let ps = "shell            99      1  2 15:48:59 ?     00:00:01 screenrecord --time-limit 179 /sdcard/mirra-rec-xyz.seg1.mp4"
        XCTAssertEqual(ScreenRecordingService.screenRecordPids(in: ps, matching: "mirra-rec-xyz.seg1.mp4"), [99])
    }

    func testDefaultFileNameSanitizesModelAndFormatsDate() {
        var components = DateComponents()
        components.year = 2026; components.month = 11; components.day = 12
        components.hour = 15; components.minute = 30; components.second = 4
        let utc = TimeZone(identifier: "UTC")!
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = utc
        let date = utcCalendar.date(from: components)!
        XCTAssertEqual(
            ScreenRecordingService.defaultFileName(model: "SM A325F", date: date, timeZone: utc),
            "recording-SM-A325F-20261112-153004.mp4"
        )
        XCTAssertEqual(
            ScreenRecordingService.defaultFileName(model: "", date: date, timeZone: utc),
            "recording-device-20261112-153004.mp4"
        )
    }

    func testElapsedLabelFormatsMinutesAndSeconds() {
        XCTAssertEqual(ScreenRecordingService.elapsedLabel(0), "00:00")
        XCTAssertEqual(ScreenRecordingService.elapsedLabel(83), "01:23")
        XCTAssertEqual(ScreenRecordingService.elapsedLabel(3600), "60:00")
        XCTAssertEqual(ScreenRecordingService.elapsedLabel(-5), "00:00")
    }

    func testQualityTiersMapToBitRates() {
        XCTAssertEqual(ScreenRecordingService.Quality.high.bitRate, "8000000")
        XCTAssertEqual(ScreenRecordingService.Quality.medium.bitRate, "4000000")
        XCTAssertEqual(ScreenRecordingService.Quality.low.bitRate, "2000000")
        XCTAssertEqual(ScreenRecordingService.Quality.allCases.count, 3)
    }

    func testQualityRoundTripsThroughRawValue() {
        for quality in ScreenRecordingService.Quality.allCases {
            XCTAssertEqual(ScreenRecordingService.Quality(rawValue: quality.rawValue), quality)
        }
        XCTAssertNil(ScreenRecordingService.Quality(rawValue: "ultra"))
    }
}
