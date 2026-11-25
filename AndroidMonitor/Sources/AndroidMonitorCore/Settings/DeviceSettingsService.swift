import Foundation

/// Quick device setting changes used for QA: locale, font scale, animation speed, rotation,
/// network toggles and display metrics. All shapes validated against a real Samsung device.
public struct DeviceSettingsService: Sendable {
    private let adb: any ADBServing
    private let serial: String

    public init(adb: any ADBServing, serial: String) {
        self.adb = adb
        self.serial = serial
    }

    // MARK: - Locale

    /// System-wide language cannot be changed from a shell without root or a reboot
    /// (`persist.sys.locale` is write-protected), so the panel offers the two paths that
    /// actually work: a per-app locale, and opening the device's own language screen.

    /// `cmd locale set-app-locales <pkg> --locales <tag>` (Android 13+; apps declaring
    /// localeConfig honour it).
    public func setAppLocale(package: String, locale: String) async throws {
        _ = try await adb.run(
            serial: serial,
            arguments: ["shell", "cmd", "locale", "set-app-locales", package, "--locales", locale],
            timeout: .seconds(10)
        )
        try await refreshUI()
    }

    /// Clears the app's locale override.
    public func clearAppLocale(package: String) async throws {
        _ = try await adb.run(
            serial: serial,
            arguments: ["shell", "cmd", "locale", "set-app-locales", package],
            timeout: .seconds(10)
        )
        try await refreshUI()
    }

    /// Opens the phone's own language & input screen (the only way to change system language).
    public func openLanguageSettings() async throws {
        _ = try await adb.run(serial: serial, arguments: ["shell", "am", "start", "-a", "android.settings.LOCALE_SETTINGS"], timeout: .seconds(10))
    }

    /// Pokes the framework so pending setting changes are applied and the screen repaints.
    /// Some builds (Samsung) apply a settings write only on the next relayout, which is why
    /// the mirror used to need a manual tap after Apply.
    public func refreshUI() async throws {
        _ = try await adb.run(serial: serial, arguments: ["shell", "input", "keyevent", "224"], timeout: .seconds(10)) // KEYCODE_WAKEUP: no-op that forces a repaint
    }

    // MARK: - Display

    public func setFontScale(_ scale: Double) async throws {
        try await put("system", "font_scale", String(format: "%.2f", scale))
        try await refreshUI()
    }

    public func setDensity(_ dpi: Int) async throws {
        _ = try await adb.run(serial: serial, arguments: ["shell", "wm", "density", String(dpi)], timeout: .seconds(10))
        try await refreshUI()
    }

    public func resetDensity() async throws {
        _ = try await adb.run(serial: serial, arguments: ["shell", "wm", "density", "reset"], timeout: .seconds(10))
        try await refreshUI()
    }

    public func setScreenSize(_ width: Int, _ height: Int) async throws {
        _ = try await adb.run(serial: serial, arguments: ["shell", "wm", "size", "\(width)x\(height)"], timeout: .seconds(10))
        try await refreshUI()
    }

    public func resetScreenSize() async throws {
        _ = try await adb.run(serial: serial, arguments: ["shell", "wm", "size", "reset"], timeout: .seconds(10))
        try await refreshUI()
    }

    /// `0` disables all three animation scales; `1` restores them.
    public func setAnimationScale(_ scale: Double) async throws {
        try await put("global", "window_animation_scale", String(format: "%.1f", scale))
        try await put("global", "transition_animation_scale", String(format: "%.1f", scale))
        try await put("global", "animator_duration_scale", String(format: "%.1f", scale))
        try await refreshUI()
    }

    /// Auto-rotate on/off; when off, `rotation` (0=portrait, 1=landscape, 2=reverse portrait, 3=reverse landscape) sticks.
    public func setAutoRotate(_ enabled: Bool) async throws {
        try await put("system", "accelerometer_rotation", enabled ? "1" : "0")
        try await refreshUI()
    }

    public func setRotation(_ rotation: Int) async throws {
        try await put("system", "user_rotation", String(rotation))
        try await refreshUI()
    }

    // MARK: - Network

    public func setWiFi(_ enabled: Bool) async throws {
        _ = try await adb.run(serial: serial, arguments: ["shell", "svc", "wifi", enabled ? "enable" : "disable"], timeout: .seconds(10))
        try await refreshUI()
    }

    public func setCellularData(_ enabled: Bool) async throws {
        _ = try await adb.run(serial: serial, arguments: ["shell", "svc", "data", enabled ? "enable" : "disable"], timeout: .seconds(10))
        try await refreshUI()
    }

    /// `cmd connectivity airplane-mode` (Android 13+); falls back to the settings key + broadcast.
    public func setAirplaneMode(_ enabled: Bool) async throws {
        let modern = try? await adb.run(serial: serial, arguments: ["shell", "cmd", "connectivity", "airplane-mode", enabled ? "enable" : "disable"], timeout: .seconds(10))
        if modern != nil, let output = modern, !String(decoding: output.stderr, as: UTF8.self).contains("Unknown command") {
            try await refreshUI()
            return
        }
        try await put("global", "airplane_mode_on", enabled ? "1" : "0")
        _ = try? await adb.run(serial: serial, arguments: ["shell", "am", "broadcast", "-a", "android.intent.action.AIRPLANE_MODE", "--ez", "state", enabled ? "true" : "false"], timeout: .seconds(10))
        try await refreshUI()
    }

    // MARK: - Helpers

    private func put(_ namespace: String, _ key: String, _ value: String) async throws {
        _ = try await adb.run(serial: serial, arguments: ["shell", "settings", "put", namespace, key, value], timeout: .seconds(10))
    }
}
