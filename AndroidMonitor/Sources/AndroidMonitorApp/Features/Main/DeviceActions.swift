import AppKit
import SwiftUI

@MainActor
enum DeviceActions {
    static func screenshot(serial: String) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "screenshot-\(serial).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let adb = ADBClient(adbURL: AppADB.url)
            if let result = try? await adb.run(serial: serial, arguments: ["exec-out", "screencap", "-p"], timeout: .seconds(20)) {
                try? result.stdout.write(to: url, options: .atomic)
            }
        }
    }

    static func pasteText(serial: String) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        let safe = text.replacingOccurrences(of: " ", with: "%s")
        Task {
            let adb = ADBClient(adbURL: AppADB.url)
            _ = try? await adb.run(serial: serial, arguments: ["shell", "input", "text", safe], timeout: .seconds(10))
        }
    }
}

@MainActor
final class PairingWindowController: NSObject {
    static let shared = PairingWindowController()
    private var window: NSWindow?

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let created = NSWindow(contentViewController: NSHostingController(rootView: PairingView()))
        created.title = "Connect over Wi-Fi"; created.styleMask = [.titled, .closable]
        created.isReleasedWhenClosed = false
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: created, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.window = nil }
        }
        created.center(); created.makeKeyAndOrderFront(nil); window = created
    }
}
