import Foundation

/// Unicode text injection for the Android mirror via the open-source ADBKeyboard IME
/// (github.com/senzhk/ADBKeyBoard). Android's `input text` is ASCII-only, so typing Persian or
/// emoji needs an IME that accepts a UTF-8 string and emits the characters itself.
public struct ADBKeyboard: Sendable {
    public static let apkURL = URL(string: "https://github.com/senzhk/ADBKeyBoard/raw/master/ADBKeyboard.apk")!
    public static let package = "com.android.adbkeyboard"
    public static let ime = "com.android.adbkeyboard/.AdbIME"
    public static let messageAction = "ADB_INPUT_TEXT"
    /// The current ADBKeyboard release expects base64 in `ADB_INPUT_B64`; `ADB_INPUT_TEXT` only
    /// handles plain ASCII reliably. Sending base64 through this action is the correct path.
    public static let base64Action = "ADB_INPUT_B64"
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

    /// Enables and selects the ADBKeyboard IME. `ime set` alone fails on some Samsung builds
    /// when the IME was never enabled, so enable first; success is verified by reading the
    /// secure setting back rather than parsing command output.
    public func activate() async -> Bool {
        _ = try? await adb.run(serial: serial, arguments: ["shell", "ime", "enable", Self.ime], timeout: .seconds(10))
        _ = try? await adb.run(serial: serial, arguments: ["shell", "ime", "set", Self.ime], timeout: .seconds(10))
        return await currentIME().contains(Self.package)
    }

    // MARK: - Typing

    /// Sends any UTF-8 string through the IME's broadcast receiver. base64 is required for non-ASCII.
    public func type(text: String) async throws {
        let encoded = Data(text.utf8).base64EncodedString()
        _ = try await adb.run(serial: serial, arguments: ["shell", "am", "broadcast", "-a", Self.base64Action, "--es", "msg", encoded], timeout: .seconds(15))
    }

    /// Shows the previous keyboard again (the IME's "switch back" broadcast) when it is known.
    public func switchBack() async {
        guard let result = try? await adb.run(serial: serial, arguments: ["shell", "am", "broadcast", "-a", Self.previousAction], timeout: .seconds(10)) else { return }
        _ = result
    }
}
