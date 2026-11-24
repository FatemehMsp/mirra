import Foundation

/// Unicode text injection for the Android mirror via the open-source ADBKeyboard IME
/// (github.com/senzhk/ADBKeyBoard). Android's `input text` is ASCII-only, so typing Persian or
/// emoji needs an IME that accepts a UTF-8 string and emits the characters itself.
public struct ADBKeyboard: Sendable {
    public static let apkURL = URL(string: "https://github.com/senzhk/ADBKeyBoard/raw/master/ADBKeyboard.apk")!
    public static let package = "com.android.adbkeyboard"
    public static let ime = "com.android.adbkeyboard/.AdbIME"
    public static let messageAction = "ADB_INPUT_TEXT"
    public static let previousAction = "ADB_PREVIOUS_KEYBOARD"

    private let adb: any ADBServing
    private let serial: String

    public init(adb: any ADBServing, serial: String) {
        self.adb = adb
        self.serial = serial
    }

    // MARK: - Availability

    /// True when the ADBKeyboard IME is installed.
    public func isInstalled() async -> Bool {
        let result = try? await adb.run(serial: serial, arguments: ["shell", "pm", "list", "packages", Self.package], timeout: .seconds(10))
        return result.map { String(decoding: $0.stdout, as: UTF8.self).contains(Self.package) } ?? false
    }

    /// The IME the device currently uses, e.g. "com.google.android.inputmethod.latin/...LatinIME".
    public func currentIME() async -> String {
        let result = try? await adb.run(serial: serial, arguments: ["shell", "settings", "get", "secure", "default_input_method"], timeout: .seconds(10))
        return result.map { String(decoding: $0.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
    }

    /// Switches the device to the ADBKeyboard IME. Returns false when the device needs a manual
    /// step (some Samsung builds require selecting it in the IME picker).
    public func activate() async -> Bool {
        let result = try? await adb.run(serial: serial, arguments: ["shell", "ime", "set", Self.ime], timeout: .seconds(10))
        let output = result.map { String(decoding: $0.stdout, as: UTF8.self) } ?? ""
        return !output.localizedCaseInsensitiveContains("error")
    }

    // MARK: - Typing

    /// Sends any UTF-8 string through the IME's broadcast receiver. base64 is required for non-ASCII.
    public func type(text: String) async throws {
        let encoded = Data(text.utf8).base64EncodedString()
        _ = try await adb.run(serial: serial, arguments: ["shell", "am", "broadcast", "-a", Self.messageAction, "--es", "msg", encoded], timeout: .seconds(15))
    }

    /// Shows the previous keyboard again (the IME's "switch back" broadcast) when it is known.
    public func switchBack() async {
        guard let result = try? await adb.run(serial: serial, arguments: ["shell", "am", "broadcast", "-a", Self.previousAction], timeout: .seconds(10)) else { return }
        _ = result
    }
}
