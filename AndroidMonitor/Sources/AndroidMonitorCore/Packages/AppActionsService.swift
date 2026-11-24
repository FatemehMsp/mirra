import Foundation

/// One-click app QA actions on a device.
public struct AppActionsService: Sendable {
    private let adb: any ADBServing
    private let serial: String

    public init(adb: any ADBServing, serial: String) {
        self.adb = adb
        self.serial = serial
    }

    /// `pm clear` — wipes the app's data and cache.
    public func clearData(package: String) async throws {
        _ = try await adb.run(serial: serial, arguments: ["shell", "pm", "clear", package], timeout: .seconds(20))
    }

    /// Grants every runtime permission the app declares (used after Clear Data to avoid first-run dialogs).
    public func grantAllPermissions(package: String) async throws {
        let result = try await adb.run(serial: serial, arguments: ["shell", "pm", "dump", package], timeout: .seconds(20))
        for permission in Self.requestedPermissions(in: String(decoding: result.stdout, as: UTF8.self)) {
            _ = try? await adb.run(serial: serial, arguments: ["shell", "pm", "grant", package, permission], timeout: .seconds(15))
        }
    }
    public static func requestedPermissions(in dump: String) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for line in dump.split(separator: "\n") {
            guard line.contains("android.permission.") else { continue }
            guard let range = line.range(of: "android.permission.") else { continue }
            let permission = String(line[range.lowerBound...])
                .split(separator: " ").first?
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,:"))
            guard let permission, permission.count > 20, !seen.contains(permission) else { continue }
            seen.insert(permission)
            result.append(permission)
        }
        return result
    }

    /// Launches a deep link (http(s), app scheme, or intent URI).
    public func launch(deepLink: String) async throws {
        _ = try await adb.run(serial: serial, arguments: ["shell", "am", "start", "-a", "android.intent.action.VIEW", "-d", deepLink], timeout: .seconds(15))
    }

    /// `cmd uimode night yes|no` — flips the whole device to dark or light.
    public func setDarkMode(_ enabled: Bool) async throws {
        _ = try await adb.run(serial: serial, arguments: ["shell", "cmd", "uimode", "night", enabled ? "yes" : "no"], timeout: .seconds(10))
    }
}
