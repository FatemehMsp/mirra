import Foundation

/// Runtime permission management: list an app's permissions with their granted state,
/// flip them individually, revoke everything, or grant everything.
public struct PermissionsService: Sendable {
    public struct Permission: Identifiable, Sendable, Equatable {
        public var id: String { name }
        public let name: String
        public let granted: Bool
    }

    private let adb: any ADBServing
    private let serial: String

    public init(adb: any ADBServing, serial: String) {
        self.adb = adb
        self.serial = serial
    }

    /// Runtime permissions of an app from `pm dump`, with granted state. A dump can contain
    /// several "runtime permissions:" blocks (one per user/profile); they are merged.
    public func list(package: String) async throws -> [Permission] {
        let result = try await adb.run(serial: serial, arguments: ["shell", "pm", "dump", package], timeout: .seconds(20))
        return Self.parse(String(decoding: result.stdout, as: UTF8.self))
    }

    public static func parse(_ dump: String) -> [Permission] {
        var states: [String: Bool] = [:]
        var order: [String] = []
        var inRuntimeBlock = false
        for line in dump.split(separator: "\n") {
            if line.contains("runtime permissions:") { inRuntimeBlock = true; continue }
            if inRuntimeBlock {
                guard line.contains("android.permission.") else {
                    if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                    inRuntimeBlock = false
                    continue
                }
                let entry = line.trimmingCharacters(in: .whitespaces)
                let name = String(entry.split(separator: ":").first ?? "")
                let granted = entry.contains("granted=true")
                guard name.hasPrefix("android.permission.") else { continue }
                if states[name] == nil { order.append(name) }
                // A dump can repeat a permission per user/profile; the last block wins.
                states[name] = granted
            }
        }
        return order
            .compactMap { name in states[name].map { Permission(name: name, granted: $0) } }
            .sorted { $0.name < $1.name }
    }

    public func grant(package: String, permission: String) async throws {
        _ = try await adb.run(serial: serial, arguments: ["shell", "pm", "grant", package, permission], timeout: .seconds(10))
    }

    public func revoke(package: String, permission: String) async throws {
        _ = try await adb.run(serial: serial, arguments: ["shell", "pm", "revoke", package, permission], timeout: .seconds(10))
    }

    /// Revokes every currently granted runtime permission (permissions granted by default
    /// or by role may come back — the device decides).
    public func revokeAll(package: String) async throws {
        for permission in try await list(package: package) where permission.granted {
            try? await revoke(package: package, permission: permission.name)
        }
    }

    /// Grants every runtime permission the app declares.
    public func grantAll(package: String) async throws {
        for permission in try await list(package: package) where !permission.granted {
            try? await grant(package: package, permission: permission.name)
        }
    }
}
