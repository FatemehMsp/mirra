import Foundation

/// Two-way text clipboard sync between the Mac and an iPhone / iPad, using `devicectl device pasteboard sync-with-host`.
/// devicectl ends a sync session after a while, so it is restarted until the user turns it off.
@MainActor
final class IOSClipboardSync: ObservableObject {
    @Published private(set) var enabled = false
    @Published var status: String?
    private var statusTask: Task<Void, Never>?

    private func say(_ text: String, keep: Bool = false) {
        status = text
        statusTask?.cancel()
        guard !keep else { return }
        statusTask = Task { try? await Task.sleep(for: .seconds(5)); if !Task.isCancelled { status = nil } }
    }

    private let deviceID: String
    private var process: Process?
    private var loop: Task<Void, Never>?

    init(deviceID: String) { self.deviceID = deviceID }

    func toggle() { enabled ? stop() : start() }

    func start() {
        guard !enabled else { return }
        enabled = true
        say("Clipboard sync on. Copy on one device, paste on the other.")
        loop = Task { [weak self] in
            var quickFailures = 0
            while !Task.isCancelled {
                guard let self else { return }
                let began = Date()
                let message = await self.runOnce()
                if Task.isCancelled { return }
                if Date().timeIntervalSince(began) < 5 {
                    quickFailures += 1
                    if quickFailures >= 3 {
                        self.say(message ?? "Clipboard sync stopped.", keep: true)
                        self.enabled = false
                        return
                    }
                } else { quickFailures = 0 }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        loop?.cancel(); loop = nil
        process?.terminate(); process = nil
        if enabled { say("Clipboard sync off") }
        enabled = false
    }

    /// Runs one devicectl sync session; returns an error message if it failed.
    private func runOnce() async -> String? {
        let p = Process()
        let errors = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["devicectl", "device", "pasteboard", "sync-with-host", "--device", deviceID, "--session-timeout", "86400", "--timeout", "86400"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = errors
        process = p
        guard (try? p.run()) != nil else { return IOSServiceError.xcodeMissing.localizedDescription }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            p.terminationHandler = { _ in continuation.resume() }
        }
        let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return p.terminationStatus == 0 ? nil : IOSDeviceService.friendlyMessage(for: text)
    }
}
