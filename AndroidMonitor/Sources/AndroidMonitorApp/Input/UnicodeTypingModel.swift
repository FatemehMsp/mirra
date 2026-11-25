import Foundation

/// Shared ADBKeyboard-IME lifecycle for one Android device, owned by the mirror view so both the
/// Actions panel toggle and the mirror's keyboard input use the same state.
@MainActor
final class UnicodeTypingModel: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var busy = false
    @Published private(set) var status: String?

    private let serial: String
    private var previousIME: String?

    init(serial: String) { self.serial = serial }

    private var adb: ADBClient { ADBClient(adbURL: AppADB.url) }
    private var keyboard: ADBKeyboard { ADBKeyboard(adb: adb, serial: serial) }

    func toggle() {
        if enabled { disable() } else { enable() }
    }

    func enable() {
        guard !busy else { return }
        busy = true
        status = nil
        let serial = serial
        Task {
            let keyboard = ADBKeyboard(adb: ADBClient(adbURL: AppADB.url), serial: serial)
            do {
                if !(await keyboard.isInstalled()) {
                    status = "Installing ADBKeyboard…"
                    let destination = FileManager.default.temporaryDirectory.appendingPathComponent("ADBKeyboard.apk")
                    let (data, _) = try await URLSession.shared.data(from: ADBKeyboard.apkURL)
                    try data.write(to: destination)
                    _ = try await ADBClient(adbURL: AppADB.url).run(serial: serial, arguments: ["install", destination.path], timeout: .seconds(60))
                }
                previousIME = await keyboard.currentIME()
                if await keyboard.activate() {
                    enabled = true
                    status = "Unicode typing is on. Click the mirror and type."
                } else {
                    status = "Could not switch keyboard — enable ADBKeyboard in the device's IME settings, then try again."
                }
            } catch {
                status = "Enable failed: \(error.localizedDescription)"
            }
            busy = false
        }
    }

    func disable() {
        guard !busy else { return }
        busy = true
        status = nil
        let previous = previousIME
        let serial = serial
        Task {
            if let previous, !previous.isEmpty {
                _ = try? await ADBClient(adbURL: AppADB.url).run(serial: serial, arguments: ["shell", "ime", "set", previous], timeout: .seconds(10))
            }
            enabled = false
            previousIME = nil
            busy = false
            status = "Unicode typing is off."
        }
    }

    /// Types text through the IME. The caller guarantees `enabled` is true.
    func type(_ text: String) {
        guard enabled else { return }
        Task { try? await keyboard.type(text: text) }
    }

    /// Restores the previous keyboard when the mirror goes away.
    func restoreOnStop() {
        guard enabled else { return }
        disable()
    }
}
