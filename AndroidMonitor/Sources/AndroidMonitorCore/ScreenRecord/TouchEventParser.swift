import Foundation

/// One user touch on the device screen, already converted to screen pixel coordinates.
public struct TouchEvent: Sendable {
    public enum Kind: Sendable {
        case tap(x: Double, y: Double)
        case swipe(points: [(x: Double, y: Double)])
    }

    public let timestamp: Date
    public let kind: Kind

    public init(timestamp: Date, kind: Kind) {
        self.timestamp = timestamp
        self.kind = kind
    }
}

/// Turns `getevent -l -t <device>` lines into `TouchEvent`s.
///
/// The device reports protocol-B multitouch events in panel coordinates (0…max), which are
/// scaled to screen pixels. A gesture (finger down → moves → lift) becomes a tap when it barely
/// moved, otherwise a swipe through the sampled points.
public final class TouchEventParser {
    public struct Config: Sendable, Equatable {
        public let panelMaxX: Double
        public let panelMaxY: Double
        public let screenWidth: Double
        public let screenHeight: Double
        public let tapMaxTravel: Double

        public init(panelMaxX: Double, panelMaxY: Double, screenWidth: Double, screenHeight: Double, tapMaxTravel: Double = 30) {
            self.panelMaxX = panelMaxX
            self.panelMaxY = panelMaxY
            self.screenWidth = screenWidth
            self.screenHeight = screenHeight
            self.tapMaxTravel = tapMaxTravel
        }
    }

    private let config: Config
    /// monotonic seconds (since boot) → wall-clock seconds
    private let bootOffset: TimeInterval
    private struct Slot {
        var trackingId: Int?
        var x: Double?
        var y: Double?
        var pending = false
        var points: [(x: Double, y: Double, t: Date)] = []
    }
    private var slots: [Int: Slot] = [:]
    private var currentSlot = 0

    public init(config: Config, bootOffset: TimeInterval) {
        self.config = config
        self.bootOffset = bootOffset
    }

    /// Feeds one output line; returns any gestures that completed on it.
    public func parse(line rawLine: String) -> [TouchEvent] {
        let line = rawLine.replacingOccurrences(of: "\r", with: "")
        guard line.contains("EV_ABS") || line.contains("EV_SYN") else { return [] }

        let timestamp = Self.monotonicSeconds(in: line).map { $0 + bootOffset }.map(Date.init(timeIntervalSince1970:))
        // "[   1234.567890] /dev/input/event7: EV_ABS ABS_MT_POSITION_X 00000215"
        let fields = line.split(separator: " ").map(String.init)
        guard let eventIndex = fields.firstIndex(where: { $0 == "EV_ABS" || $0 == "EV_SYN" }),
              fields.count >= eventIndex + 3 else { return [] }
        let name = fields[eventIndex + 1]
        let valueField = fields[eventIndex + 2]
        // getevent prints unsigned hex; the "finger lifted" tracking id is -1 → ffffffff.
        let value: Int
        if let raw = UInt32(valueField, radix: 16) {
            value = Int(Int32(bitPattern: raw))
        } else {
            value = Int(valueField) ?? 0
        }

        switch name {
        case "ABS_MT_SLOT":
            currentSlot = value
        case "ABS_MT_TRACKING_ID":
            if value < 0 {
                return lift(timestamp: timestamp)
            } else {
                slots[currentSlot] = Slot(trackingId: value)
            }
        case "ABS_MT_POSITION_X":
            slots[currentSlot]?.x = Double(value)
        case "ABS_MT_POSITION_Y":
            slots[currentSlot]?.y = Double(value)
        case "SYN_REPORT":
            if let timestamp, var slot = slots[currentSlot], slot.trackingId != nil,
               let x = slot.x, let y = slot.y {
                slot.points.append((screenX(x), screenY(y), timestamp))
                slot.x = nil; slot.y = nil
                slots[currentSlot] = slot
            }
        default:
            break
        }
        return []
    }

    /// Feeds a chunk of output and returns any gestures that completed in it. `isNewline` covers
    /// LF, CR and CRLF — a pty delivers CRLF, and CRLF is a single Character in Swift.
    public func parse(chunk: String) -> [TouchEvent] {
        chunk.split(whereSeparator: \.isNewline).flatMap { parse(line: String($0)) }
    }

    private func lift(timestamp: Date?) -> [TouchEvent] {
        guard var slot = slots[currentSlot] else { return [] }
        let points = slot.points
        slot.trackingId = nil
        slot.points = []
        slots[currentSlot] = slot
        guard !points.isEmpty else { return [] }

        let start = points.first!
        let travel = points.dropFirst().map { hypot($0.x - start.x, $0.y - start.y) }.max() ?? 0
        let end = points.last!
        let kind: TouchEvent.Kind = travel <= config.tapMaxTravel
            ? .tap(x: end.x, y: end.y)
            : .swipe(points: downsample(points))
        let when = timestamp ?? end.t
        return [TouchEvent(timestamp: when, kind: kind)]
    }

    private func downsample(_ points: [(x: Double, y: Double, t: Date)]) -> [(x: Double, y: Double)] {
        guard points.count > 24 else { return points.map { ($0.x, $0.y) } }
        let stride = Double(points.count - 1) / 23.0
        return (0...23).map { index in
            let point = points[min(points.count - 1, Int((Double(index) * stride).rounded()))]
            return (point.x, point.y)
        }
    }

    private func screenX(_ panelX: Double) -> Double { panelX / max(1, config.panelMaxX) * config.screenWidth }
    private func screenY(_ panelY: Double) -> Double { panelY / max(1, config.panelMaxY) * config.screenHeight }

    /// `getevent -t` prefixes lines with the monotonic clock in `[  1234.567890]`.
    public static func monotonicSeconds(in line: String) -> TimeInterval? {
        guard let open = line.firstIndex(of: "["), let close = line[open...].firstIndex(of: "]") else { return nil }
        return TimeInterval(line[line.index(after: open)..<close].trimmingCharacters(in: .whitespaces))
    }

    /// Finds the touchscreen and its panel coordinate range in `getevent -pl` output: the device
    /// block reporting `ABS_MT_POSITION_X` (only the touchscreen does).
    public static func touchscreen(in listing: String) -> (path: String, maxX: Double, maxY: Double)? {
        for block in listing.components(separatedBy: "add device") {
            guard block.contains("ABS_MT_POSITION_X") else { continue }
            guard let path = block.split(separator: "\n").first?
                .split(separator: ":").last?
                .trimmingCharacters(in: .whitespaces) else { continue }
            let maxX = Self.absMax(named: "ABS_MT_POSITION_X", in: block) ?? 4095
            let maxY = Self.absMax(named: "ABS_MT_POSITION_Y", in: block) ?? 4095
            return (path, maxX, maxY)
        }
        return nil
    }

    private static func absMax(named name: String, in block: String) -> Double? {
        for line in block.split(separator: "\n") where line.contains(name) {
            guard let range = line.range(of: "max ") else { continue }
            let tail = line[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
            let digits = tail.prefix { $0.isNumber }
            return Double(digits)
        }
        return nil
    }

    /// `Physical size: 1080x2400` (or `Override size:` when set) from `wm size`.
    public static func screenSize(in output: String) -> (width: Double, height: Double)? {
        for key in ["Override size:", "Physical size:"] {
            if let range = output.range(of: key) {
                let tail = output[range.upperBound...].prefix(20)
                let dims = tail.split(whereSeparator: { $0 == "x" || $0 == "\n" })
                    .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                if dims.count >= 2 { return (dims[0], dims[1]) }
            }
        }
        return nil
    }
}
