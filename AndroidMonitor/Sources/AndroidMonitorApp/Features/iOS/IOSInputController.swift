import SwiftUI

/// Drives the "touch control" feature for one iOS device: builds/launches WebDriverAgent,
/// tunnels usbmuxd to its HTTP port, and forwards mirror gestures as W3C pointer actions.
///
/// Signing with a free Apple ID lasts 7 days; when the runner fails to launch because of it,
/// the state becomes `.failed` with a renew hint and `renew()` rebuilds.
@MainActor
final class IOSInputController: ObservableObject {
    enum State: Equatable {
        case off
        case building(String)
        case launching(String)
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .off
    /// True when the failure looks like an expired free signature, so the UI can offer Renew.
    @Published private(set) var needsRenewal = false

    private let udid: String
    private let setup = WDASetupService()
    private var forwarder: USBMuxPortForwarder?
    private var client: WDAClient?
    private var sessionId: String?
    private var launchTask: Task<Void, Never>?
    /// Screen size in points as reported by WDA — the coordinate space of its actions.
    private(set) var screenSize: (width: Double, height: Double) = (0, 0)

    init(udid: String) {
        self.udid = udid
    }

    var isReady: Bool { state == .ready }

    // MARK: - Lifecycle

    func enable() {
        switch state {
        case .off, .failed:
            begin()
        default:
            break
        }
    }

    /// Rebuilds and relaunches after the 7-day free signature expires (or after any failure).
    func renew() {
        guard case .failed = state else { return }
        needsRenewal = false
        begin()
    }

    func disable() {
        stop()
    }

    private func begin() {
        state = .building("Checking signing identity…")
        let setup = setup
        let udid = udid
        Task {
            do {
                guard let team = await setup.signingTeam() else {
                    throw WDASetupService.SetupError.noSigningTeam
                }
                state = .building("Building WebDriverAgent for the device (the first run takes a few minutes)…")
                let xctestrun = try await setup.build(udid: udid, team: team)
                try await startRunner(xctestrun: xctestrun)
            } catch {
                fail(error)
            }
        }
    }

    private func startRunner(xctestrun: String) async throws {
        state = .launching("Starting WebDriverAgent on the device…")
        // The xcodebuild process must stay alive for the WDA server to keep running.
        let stream = setup.launchStream(udid: udid, xctestrun: xctestrun)
        launchTask = Task { [weak self] in
            do {
                for try await _ in stream {}
                // The runner exited; if control was live it just ended (e.g. device rebooted).
                self?.runnerDidExit(nil)
            } catch {
                self?.runnerDidExit(error)
            }
        }

        let forwarder = USBMuxPortForwarder(deviceSerial: udid, devicePort: 8100)
        let port = try forwarder.start()
        self.forwarder = forwarder
        let client = WDAClient(port: port)
        self.client = client
        state = .launching("Waiting for WebDriverAgent (up to a minute)…")
        guard await client.waitUntilReady(timeout: 90) else {
            throw WDAClient.WDAError.notReady
        }
        let session = try await client.createSession()
        let size = try await client.windowSize(sessionId: session)
        sessionId = session
        screenSize = size
        state = .ready
    }

    private func runnerDidExit(_ error: (any Error)?) {
        var detail = ""
        if case let CommandError.nonZeroExit(_, stderr)? = error, !stderr.isEmpty {
            detail = " (\(String(stderr.prefix(150))))"
        }
        // If a launch was in flight it has just failed; if control was live it ended (e.g. reboot).
        let wasActive: Bool
        switch state {
        case .ready, .launching: wasActive = true
        case .off, .building, .failed: wasActive = false
        }
        guard wasActive else { return }
        stop()
        state = .failed("WebDriverAgent stopped\(detail) — press Retry.")
    }

    private func fail(_ error: Error) {
        stop()
        let message = error.localizedDescription
        needsRenewal = message.contains("expired") || message.contains("no longer valid")
        state = .failed(message)
    }

    private func stop() {
        launchTask?.cancel(); launchTask = nil
        forwarder?.stop(); forwarder = nil
        client = nil
        sessionId = nil
        needsRenewal = false
    }

    // MARK: - Gestures (screen points, from the mirror surface)

    func tap(x: Double, y: Double) {
        guard isReady, let client, let sessionId else { return }
        Task {
            try? await client.tap(sessionId: sessionId, x: x, y: y)
        }
    }

    func drag(from: (x: Double, y: Double), to: (x: Double, y: Double), durationMs: Int) {
        guard isReady, let client, let sessionId else { return }
        Task {
            try? await client.drag(sessionId: sessionId, from: from, to: to, durationMs: max(120, min(durationMs, 2000)))
        }
    }

    /// Scroll wheel becomes a vertical swipe, like the Android mirror.
    func scroll(x: Double, y: Double, delta: Double) {
        guard isReady, let client, let sessionId, screenSize.height > 0 else { return }
        let travel = max(-screenSize.height * 0.4, min(screenSize.height * 0.4, delta * 12))
        Task {
            try? await client.drag(
                sessionId: sessionId,
                from: (x, y),
                to: (x, min(max(y + travel, 0), screenSize.height)),
                durationMs: 250
            )
        }
    }
}
