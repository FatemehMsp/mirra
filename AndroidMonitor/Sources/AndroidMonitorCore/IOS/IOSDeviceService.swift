import Foundation

public struct IOSDevice: Identifiable, Hashable, Sendable {
    public enum Transport: String, Sendable { case usb = "wired", wifi = "localNetwork", other }
    public let id: String          // CoreDevice identifier
    public let udid: String
    public let name: String
    public let model: String       // e.g. "iPhone 15 Pro"
    public let osVersion: String
    public let transport: Transport
    public let isConnected: Bool   // tunnel is up; the device can be driven right now
}

public struct IOSApp: Identifiable, Hashable, Sendable {
    public var id: String { bundleID }
    public let bundleID: String
    public let name: String
    public let version: String
    public let isUserApp: Bool
}

public enum IOSServiceError: Error, LocalizedError {
    case xcodeMissing
    case failed(String)
    public var errorDescription: String? {
        switch self {
        case .xcodeMissing: return "Xcode command line tools (devicectl, Xcode 15+) are required for iPhone support."
        case .failed(let text): return text
        }
    }
}

/// iPhone / iPad support built on Apple's `devicectl` (Xcode 15+, devices on iOS 17+). Nothing is installed on the device.
public struct IOSDeviceService: Sendable {
    private let runner: any CommandRunning
    private let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")

    public init(runner: any CommandRunning = ProcessCommandRunner()) { self.runner = runner }

    public static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") }

    // MARK: Parsing (pure, unit-testable)

    public static func parseDevices(_ data: Data) -> [IOSDevice] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let devices = result["devices"] as? [[String: Any]] else { return [] }
        return devices.compactMap { device in
            let hardware = (device["hardwareProperties"] as? [String: Any]) ?? ((device["properties"] as? [String: Any])?["hardware"] as? [String: Any]) ?? [:]
            guard (hardware["reality"] as? String ?? "physical") == "physical",
                  let platform = hardware["platform"] as? String, platform == "iOS" || platform == "iPadOS",
                  let id = device["identifier"] as? String else { return nil }
            let deviceProps = (device["deviceProperties"] as? [String: Any]) ?? [:]
            let connection = (device["connectionProperties"] as? [String: Any]) ?? ((device["properties"] as? [String: Any])?["connection"] as? [String: Any]) ?? [:]
            let transportRaw = connection["transportType"] as? String ?? ""
            let tunnel = (connection["tunnelState"] as? String) ?? (connection["state"] as? String) ?? ""
            return IOSDevice(
                id: id,
                udid: hardware["udid"] as? String ?? id,
                name: deviceProps["name"] as? String ?? (hardware["marketingName"] as? String ?? "iPhone"),
                model: hardware["marketingName"] as? String ?? (hardware["productType"] as? String ?? "iOS device"),
                osVersion: deviceProps["osVersionNumber"] as? String ?? "",
                transport: IOSDevice.Transport(rawValue: transportRaw) ?? .other,
                isConnected: tunnel == "connected" || tunnel == "available"
            )
        }
    }

    public static func parseApps(_ data: Data) -> [IOSApp] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let apps = result["apps"] as? [[String: Any]] else { return [] }
        return apps.compactMap { app in
            guard let bundle = app["bundleIdentifier"] as? String else { return nil }
            return IOSApp(
                bundleID: bundle,
                name: app["name"] as? String ?? bundle,
                version: app["version"] as? String ?? "",
                isUserApp: (app["removable"] as? Bool) ?? false
            )
        }
    }

    // MARK: devicectl

    private func json(_ arguments: [String], timeout: Duration = .seconds(60)) async throws -> Data {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("devicectl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let result = try await runner.run(CommandRequest(executable: xcrun, arguments: ["devicectl"] + arguments + ["--json-output", file.path], timeout: timeout))
        if result.exitCode != 0 {
            let text = String(decoding: result.stderr.isEmpty ? result.stdout : result.stderr, as: UTF8.self)
            throw IOSServiceError.failed(text.split(separator: "\n").last.map(String.init) ?? "devicectl failed")
        }
        return (try? Data(contentsOf: file)) ?? Data()
    }

    public func devices() async throws -> [IOSDevice] {
        Self.parseDevices(try await json(["list", "devices"], timeout: .seconds(20)))
    }

    public func apps(of device: IOSDevice) async throws -> [IOSApp] {
        Self.parseApps(try await json(["device", "info", "apps", "--device", device.id, "--include-all-apps"], timeout: .seconds(60)))
    }

    public func install(_ ipa: URL, on device: IOSDevice) async throws {
        _ = try await json(["device", "install", "app", "--device", device.id, ipa.path], timeout: .seconds(900))
    }

    public func uninstall(_ bundleID: String, on device: IOSDevice) async throws {
        _ = try await json(["device", "uninstall", "app", "--device", device.id, bundleID], timeout: .seconds(120))
    }

    public func launch(_ bundleID: String, on device: IOSDevice) async throws {
        _ = try await json(["device", "process", "launch", "--device", device.id, "--terminate-existing", bundleID], timeout: .seconds(60))
    }
}
