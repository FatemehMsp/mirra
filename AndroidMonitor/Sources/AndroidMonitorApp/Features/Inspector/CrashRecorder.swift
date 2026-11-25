import Foundation
import UserNotifications

/// Keeps a rolling window of the device screen so a crash can be captured after the fact.
/// While armed, segments are recorded device-side and pulled continuously; only the last
/// `bufferSeconds` are kept. When a crash is detected, the recording stops, the window is
/// stitched and saved to ~/Downloads automatically — no save panel in the middle of a crash.
@MainActor
final class CrashRecorder: ObservableObject {
    enum State: Equatable {
        case off
        case armed
        case failed(String)
    }

    /// Rolling history kept around, in seconds.
    static let bufferSeconds: TimeInterval = 180

    @Published private(set) var state: State = .off
    @Published private(set) var armed = false

    private let serial: String
    private let service: ScreenRecordingService
    private var sessionTask: Task<Void, Never>?
    private var stopRequested = false
    private var tempDir: URL?
    private var segmentIndex = 0
    private var currentDevicePath: String?

    init(serial: String) {
        self.serial = serial
        self.service = ScreenRecordingService(adb: ADBClient(adbURL: AppADB.url), serial: serial)
    }

    // MARK: - Control

    func toggle() {
        if armed { disarm() } else { arm() }
    }

    func arm() {
        guard !armed else { return }
        let tag = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirra-crash-\(tag)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir
        segmentIndex = 0
        stopRequested = false
        armed = true
        state = .armed
        let service = service
        let crashTag = String(tag)
        sessionTask = Task { [weak self] in
            await self?.runLoop(service: service, tag: crashTag)
        }
    }

    func disarm() {
        guard armed else { return }
        stopRequested = true
        sessionTask?.cancel()
        sessionTask = nil
        if let path = currentDevicePath {
            let service = service
            Task { await service.interrupt(devicePath: path) }
        }
        armed = false
        state = .off
        if let dir = tempDir { try? FileManager.default.removeItem(at: dir); tempDir = nil }
        currentDevicePath = nil
    }

    /// Called by the crash watcher: freezes the ring buffer, saves the window, re-arms.
    func trigger(reason: String) {
        guard armed else { return }
        stopRequested = true
        let snapshotDir = tempDir
        tempDir = nil
        let service = service
        if let path = currentDevicePath {
            Task { await service.interrupt(devicePath: path) }
        }
        let serial = serial
        // Give the loop a moment to pull its in-flight segment before freezing the window.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            await self?.finalize(dir: snapshotDir, service: service, reason: reason, serial: serial)
            if self?.armed == true { self?.arm() }
        }
    }

    // MARK: - Loop

    private func runLoop(service: ScreenRecordingService, tag: String) async {
        while armed && !stopRequested, let dir = tempDir {
            let index = segmentIndex
            let devicePath = "/sdcard/mirra-crash-\(tag).seg\(index).mp4"
            segmentIndex += 1
            currentDevicePath = devicePath
            let segmentStart = Date()
            do {
                for try await _ in service.segmentStream(devicePath: devicePath, quality: .medium) {}
            } catch { break }
            if stopRequested || !armed {
                _ = try? await service.download(devicePath: devicePath, to: dir.appendingPathComponent("seg\(index).mp4"))
                Task { await service.remove(devicePath: devicePath) }
                currentDevicePath = nil
                break
            }
            // Pull the finished segment and forget anything outside the window.
            let segmentURL = dir.appendingPathComponent("seg\(index).mp4")
            _ = try? await service.download(devicePath: devicePath, to: segmentURL)
            Task { await service.remove(devicePath: devicePath) }
            currentDevicePath = nil
            prune(dir: dir, olderThan: segmentStart.addingTimeInterval(-Self.bufferSeconds - Double(ScreenRecordingService.segmentTimeLimitSeconds)))
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    /// Deletes ring-buffer segments whose recording started before `cutoff`.
    private func prune(dir: URL, olderThan cutoff: Date) {
        let contents = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for url in contents where url.lastPathComponent.hasPrefix("seg") {
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if created < cutoff { try? FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: - Finalize

    private func finalize(dir: URL?, service: ScreenRecordingService, reason: String, serial: String) async {
        guard let dir, let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
              !contents.isEmpty else {
            state = .failed("Crash recorded, but no video window was available.")
            return
        }
        let segments = contents
            .filter { $0.lastPathComponent.hasPrefix("seg") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !segments.isEmpty else {
            try? FileManager.default.removeItem(at: dir)
            state = .failed("Crash recorded, but the ring buffer was empty.")
            return
        }

        var clips = segments
        if segments.count > 1 {
            let merged = dir.appendingPathComponent("crash.mp4")
            if (try? await ScreenRecordingStitcher.stitch(segments: segments, to: merged)) != nil {
                clips = [merged]
            }
        }

        let name = CaptureName.file(prefix: "crash-\(serial)", fileExtension: "mp4", date: .now)
        let destination = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: clips[0], to: destination)
            try? FileManager.default.removeItem(at: dir)
            state = .off
            notify(title: "Crash recorded", body: "\(reason) — saved \(name) to Downloads.")
        } catch {
            state = .failed("Crash recording could not be saved: \(error.localizedDescription)")
        }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
