import Foundation

/// Bundles everything needed to file a bug into one zip: screenshot, recent logcat,
/// device properties, dumpsys sections and — when a package is given — its full pm dump.
public struct BugReportService: Sendable {
    private let adb: any ADBServing
    private let serial: String
    private let zip = URL(fileURLWithPath: "/usr/bin/zip")

    public init(adb: any ADBServing, serial: String) {
        self.adb = adb
        self.serial = serial
    }

    public struct Report: Sendable {
        public let url: URL
        public let fileCount: Int
    }

    /// Collects the report into a temp folder, zips it to `destination` and returns the summary.
    public func create(destination: URL, package: String?, logcatLines: Int = 4000) async throws -> Report {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirra-bugreport-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // 1. Screenshot.
        if let shot = try? await adb.run(serial: serial, arguments: ["exec-out", "screencap", "-p"], timeout: .seconds(15)),
           !shot.stdout.isEmpty {
            try shot.stdout.write(to: folder.appendingPathComponent("screenshot.png"), options: .atomic)
        }

        // 2. Recent logcat.
        if let logs = try? await adb.run(serial: serial, arguments: ["shell", "logcat", "-d", "-t", String(logcatLines)], timeout: .seconds(20)) {
            try String(decoding: logs.stdout, as: UTF8.self)
                .write(to: folder.appendingPathComponent("logcat.txt"), atomically: true, encoding: .utf8)
        }

        // 3. Device properties.
        if let props = try? await adb.run(serial: serial, arguments: ["shell", "getprop"], timeout: .seconds(10)) {
            try String(decoding: props.stdout, as: UTF8.self)
                .write(to: folder.appendingPathComponent("getprop.txt"), atomically: true, encoding: .utf8)
        }

        // 4. dumpsys sections (bounded; the full dump is hundreds of megabytes).
        for (name, arguments) in [
            ("dumpsys-activity.txt", ["shell", "dumpsys", "activity"]),
            ("dumpsys-window.txt", ["shell", "dumpsys", "window"]),
            ("dumpsys-battery.txt", ["shell", "dumpsys", "battery"]),
        ] {
            if let dump = try? await adb.run(serial: serial, arguments: arguments, timeout: .seconds(30)),
               !dump.stdout.isEmpty {
                try String(decoding: dump.stdout, as: UTF8.self)
                    .write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
        }

        // 5. The app's own record, when it is the suspect.
        if let package, !package.isEmpty,
           let dump = try? await adb.run(serial: serial, arguments: ["shell", "pm", "dump", package], timeout: .seconds(30)) {
            try String(decoding: dump.stdout, as: UTF8.self)
                .write(to: folder.appendingPathComponent("pm-dump.txt"), atomically: true, encoding: .utf8)
        }

        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        guard !contents.isEmpty else {
            throw BugReportError.nothingCollected
        }
        try? FileManager.default.removeItem(at: destination)
        let process = Process()
        process.executableURL = zip
        process.arguments = ["-j", "-r", destination.path, folder.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BugReportError.zipFailed
        }
        return Report(url: destination, fileCount: contents.count)
    }

    public enum BugReportError: Error, LocalizedError {
        case nothingCollected
        case zipFailed

        public var errorDescription: String? {
            switch self {
            case .nothingCollected: return "Nothing could be collected from the device"
            case .zipFailed: return "Could not package the report"
            }
        }
    }
}
