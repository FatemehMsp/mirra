import SwiftUI

/// App self-update state machine: periodic (7-day) and manual checks against GitHub Releases,
/// download with progress, and a detached install that replaces /Applications/Mirra.app.
@MainActor
final class UpdateModel: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate(shownAt: Date)
        case available(version: String)
        case downloading(fraction: Double)
        case installing
        case failed(String)
    }

    /// Checks happen on launch and then every 7 days while the app runs.
    static let checkInterval: TimeInterval = 7 * 24 * 60 * 60

    @Published private(set) var state: State = .idle
    /// Transient "you are up to date" clears itself after a few seconds.
    private var upToDateClearTask: Task<Void, Never>?
    private var downloadingTo: URL?
    private let service = UpdateService()

    // MARK: - Checks

    func checkForUpdates() {
        guard !isBusy else { return }
        state = .checking
        let service = service
        Task {
            do {
                guard let current = UpdateService.currentVersion() else {
                    throw UpdateService.UpdateError.currentVersionUnknown
                }
                guard let release = try await service.latestRelease() else {
                    setUpToDate(); return
                }
                if UpdateService.isNewer(release.version, than: current) {
                    state = .available(version: release.version)
                } else {
                    setUpToDate()
                }
            } catch {
                // Silent failures are fine for the background check, but a manual check deserves feedback.
                if case .checking = state { state = .failed("Update check failed: \(error.localizedDescription)") }
            }
        }
    }

    private var isBusy: Bool {
        switch state {
        case .downloading, .installing: return true
        default: return false
        }
    }

    private func setUpToDate() {
        state = .upToDate(shownAt: Date())
        upToDateClearTask?.cancel()
        upToDateClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            if case .upToDate = self?.state { self?.state = .idle }
        }
    }

    // MARK: - Download & install

    func downloadAndInstall() {
        guard case .available(let version) = state else { return }
        let service = service
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mirra-\(version).dmg")
        downloadingTo = destination
        state = .downloading(fraction: 0)
        Task {
            do {
                guard let release = try await service.latestRelease() else {
                    throw UpdateService.UpdateError.noDMGAsset
                }
                try await service.download(release.dmgURL, to: destination) { [weak self] fraction in
                    Task { @MainActor in
                        if case .downloading = self?.state { self?.state = .downloading(fraction: fraction) }
                    }
                }
                state = .downloading(fraction: 1)
                try await service.verify(dmg: destination, sha256URL: release.sha256URL)
                install(dmg: destination)
            } catch {
                state = .failed("Update failed: \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: destination)
            }
        }
    }

    /// Spawns the detached installer (mount DMG → replace /Applications → relaunch) and quits so
    /// the running instance does not hold the bundle. The script waits a beat before replacing.
    private func install(dmg: URL) {
        state = .installing
        let script = UpdateService.installScript(dmgPath: dmg.path)
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirra-install-\(Int(Date().timeIntervalSince1970)).sh")
        try? script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptURL.path]
        try? process.run() // detached: survives the app quitting
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            NSApp.terminate(nil)
        }
    }
}
