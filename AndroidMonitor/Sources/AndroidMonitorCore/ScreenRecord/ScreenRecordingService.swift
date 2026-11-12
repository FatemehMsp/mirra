import Foundation

/// Drives `screenrecord` on a single device.
///
/// screenrecord caps a single run at 180 seconds and only writes a playable mp4 when it exits
/// on its own or receives SIGINT, so recordings are chained from segments that stop just under
/// the cap and are stopped with `kill -INT` while finalizing.
public struct ScreenRecordingService: Sendable {
    /// Recording quality tiers: lower bit rates make much smaller files at the same resolution.
    public enum Quality: String, CaseIterable, Sendable, Identifiable {
        case high, medium, low

        public var id: String { rawValue }

        /// Bit rate passed to screenrecord.
        public var bitRate: String {
            switch self {
            case .high: return "8000000"
            case .medium: return "4000000"
            case .low: return "2000000"
            }
        }

        /// Compact toolbar label, e.g. "8 Mbps".
        public var shortLabel: String {
            switch self {
            case .high: return "8 Mbps"
            case .medium: return "4 Mbps"
            case .low: return "2 Mbps"
            }
        }

        /// Menu label with a rough size estimate, e.g. "High · 8 Mbps · ~60 MB/min".
        public var label: String {
            switch self {
            case .high: return "High · 8 Mbps · ~60 MB/min"
            case .medium: return "Medium · 4 Mbps · ~30 MB/min"
            case .low: return "Low · 2 Mbps · ~15 MB/min"
            }
        }
    }

    private let adb: any ADBServing
    private let serial: String

    /// One segment runs just under screenrecord's 180s hard cap; long recordings chain segments.
    public static let segmentTimeLimitSeconds = 179

    public init(adb: any ADBServing, serial: String) {
        self.adb = adb
        self.serial = serial
    }

    // MARK: - Segments

    /// Runs one screenrecord segment writing an mp4 to `devicePath`. The stream finishes when
    /// screenrecord exits — either because it was interrupted or because the segment hit its time limit.
    public func segmentStream(devicePath: String, quality: Quality = .high) -> AsyncThrowingStream<Data, Error> {
        adb.stream(serial: serial, arguments: [
            "shell", "screenrecord",
            "--time-limit", String(Self.segmentTimeLimitSeconds),
            "--bit-rate", quality.bitRate,
            devicePath
        ])
    }

    /// Sends SIGINT to the screenrecord instance writing `devicePath` so it finalizes the mp4
    /// instead of leaving a file without an index.
    public func interrupt(devicePath: String) async {
        guard let output = try? await adb.run(serial: serial, arguments: ["shell", "ps -ef"], timeout: .seconds(10))
        else { return }
        let pids = Self.screenRecordPids(in: String(decoding: output.stdout, as: UTF8.self), matching: devicePath)
        guard !pids.isEmpty else { return }
        _ = try? await adb.run(
            serial: serial,
            arguments: ["shell", "kill -INT " + pids.map(String.init).joined(separator: " ")],
            timeout: .seconds(10)
        )
    }

    /// Extracts the pids of the screenrecord processes writing `devicePath` from `ps -ef` output.
    /// The mirror's own screenrecord (different arguments) and any shell wrappers are ignored.
    public static func screenRecordPids(in psOutput: String, matching devicePath: String) -> [Int] {
        var pids: [Int] = []
        for rawLine in psOutput.split(separator: "\n") {
            let line = String(rawLine)
            guard line.contains(devicePath), !line.contains("sh -c"), !line.contains("grep") else { continue }
            let columns = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            // ps -ef columns: UID PID PPID … CMD
            guard columns.count > 6, let pid = Int(columns[1]) else { continue }
            if !pids.contains(pid) { pids.append(pid) }
        }
        return pids
    }

    // MARK: - Transfer

    /// Copies a finished segment off the device with `exec-out cat`, streaming to disk so large
    /// videos never sit in memory. Throws when the device copy is unreadable or empty.
    public func download(devicePath: String, to destination: URL) async throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var bytes = 0
        for try await chunk in adb.stream(serial: serial, arguments: ["exec-out", "cat", devicePath]) {
            try handle.write(contentsOf: chunk)
            bytes += chunk.count
        }
        guard bytes > 0 else {
            throw CommandError.nonZeroExit(code: 1, stderr: "empty recording segment")
        }
    }

    /// Deletes a segment from the device storage.
    public func remove(devicePath: String) async {
        _ = try? await adb.run(serial: serial, arguments: ["shell", "rm", "-f", devicePath], timeout: .seconds(30))
    }

    // MARK: - Touch capture

    /// The touchscreen device and its panel coordinate range, parsed from `getevent -pl`.
    public func touchscreen() async -> (path: String, maxX: Double, maxY: Double)? {
        guard let output = try? await adb.run(serial: serial, arguments: ["shell", "getevent", "-pl"], timeout: .seconds(10)) else { return nil }
        return TouchEventParser.touchscreen(in: String(decoding: output.stdout, as: UTF8.self))
    }

    /// Display size from `wm size`; overrides (e.g. Display Size setting) win over physical.
    public func screenSize() async -> (width: Double, height: Double)? {
        guard let output = try? await adb.run(serial: serial, arguments: ["shell", "wm", "size"], timeout: .seconds(10)) else { return nil }
        return TouchEventParser.screenSize(in: String(decoding: output.stdout, as: UTF8.self))
    }

    /// Wall-clock seconds minus the device's monotonic clock, so `getevent -t` timestamps can be
    /// converted into real dates. Measured once per recording.
    public func bootOffset() async -> TimeInterval? {
        guard let output = try? await adb.run(serial: serial, arguments: ["shell", "cat", "/proc/uptime"], timeout: .seconds(10)) else { return nil }
        guard let uptime = String(decoding: output.stdout, as: UTF8.self)
            .split(separator: " ").first.flatMap({ Double($0) }) else { return nil }
        return Date().timeIntervalSince1970 - uptime
    }

    /// Streams live touch events from the touchscreen. `-tt` forces a pty so every event line is
    /// delivered immediately instead of sitting in stdio buffers.
    public func touchStream(device: String) -> AsyncThrowingStream<Data, Error> {
        adb.stream(serial: serial, arguments: ["shell", "-tt", "getevent", "-l", "-t", device])
    }

    // MARK: - Formatting

    /// Default file name for a finished recording, e.g. `recording-SM_A325F-20261112-153004.mp4`.
    public static func defaultFileName(model: String, date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let safeModel = model
            .replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "recording-\(safeModel.isEmpty ? "device" : safeModel)-\(formatter.string(from: date)).mp4"
    }

    /// `elapsedLabel(83)` is "01:23".
    public static func elapsedLabel(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
