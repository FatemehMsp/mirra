import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Keeps one `ScreenRecorder` per serial so a recording survives switching devices in the UI —
/// the capture runs on the device, not in the window.
@MainActor
final class ScreenRecorderStore {
    static let shared = ScreenRecorderStore()
    private var recorders: [String: ScreenRecorder] = [:]

    func recorder(for serial: String, deviceName: String) -> ScreenRecorder {
        if let existing = recorders[serial] { return existing }
        let created = ScreenRecorder(serial: serial, deviceName: deviceName)
        recorders[serial] = created
        return created
    }

    /// Called by the mirror view so mouse gestures on the Mac are marked in the active recording.
    func recordMirrorTouch(serial: String, from: (Int, Int), to: (Int, Int)) {
        recorders[serial]?.appendMirrorTouch(from: from, to: to)
    }
}

/// Records the device screen with `screenrecord`, shows progress while recording, and asks
/// where to save only after the user stops — no half-finished file is left behind on stop.
@MainActor
final class ScreenRecorder: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording(started: Date)
        case saving
    }

    enum Status: Equatable {
        case saved(fileNames: [String])
        case savedMultipleClips(fileNames: [String])
        case failed(String)
        case discarded
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var status: Status?
    /// Quality for the next recording; remembered across launches. Locked while recording.
    @Published var quality: ScreenRecordingService.Quality {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: Self.qualityKey) }
    }

    private let service: ScreenRecordingService
    private let deviceName: String
    private static let qualityKey = "recordingQuality"

    private static func storedQuality() -> ScreenRecordingService.Quality {
        ScreenRecordingService.Quality(rawValue: UserDefaults.standard.string(forKey: qualityKey) ?? "") ?? .high
    }

    private struct Session {
        let tempDir: URL
        let tag: String
        let startedAt: Date
        let quality: ScreenRecordingService.Quality
        var stopRequested = false
        var failed = false
        var segmentIndex = 0
        var currentDevicePath: String?
        var completedDevicePaths: [String] = []
        var pulls: [Task<URL?, Never>] = []
        /// Touches to burn into the finished video: physical ones from getevent, mirrored ones reported by the mirror view.
        var touchEvents: [TouchEvent] = []
    }

    private var session: Session?
    private var sessionTask: Task<Void, Never>?
    private var touchTask: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var statusClearTask: Task<Void, Never>?

    init(serial: String, deviceName: String) {
        self.deviceName = deviceName
        self.service = ScreenRecordingService(adb: ADBClient(adbURL: AppADB.url), serial: serial)
        self.quality = Self.storedQuality()
    }

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    // MARK: - Control

    func start() {
        guard case .idle = phase else { return }
        status = nil
        let tag = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirra-recording-\(tag)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        session = Session(tempDir: tempDir, tag: String(tag), startedAt: Date(), quality: quality)
        phase = .recording(started: Date())
        elapsed = 0
        startTicker()
        sessionTask = Task { [weak self] in
            guard let self else { return }
            await self.runSession()
        }
    }

    func stop() {
        guard case .recording = phase, let session, let currentPath = session.currentDevicePath else { return }
        self.session?.stopRequested = true
        let service = service
        Task { await service.interrupt(devicePath: currentPath) }
    }

    // MARK: - Session

    private func runSession() async {
        startTouchCapture()
        while !Task.isCancelled, let snapshot = session, !snapshot.stopRequested, !snapshot.failed {
            let index = snapshot.segmentIndex
            let devicePath = "/sdcard/mirra-rec-\(snapshot.tag).seg\(index).mp4"
            session?.currentDevicePath = devicePath
            do {
                for try await _ in service.segmentStream(devicePath: devicePath, quality: snapshot.quality) {}
            } catch {
                session?.failed = true
                break
            }
            session?.completedDevicePaths.append(devicePath)
            session?.segmentIndex += 1
            // Pull the finished segment to the Mac while the next one records.
            session?.pulls.append(pull(devicePath: devicePath, index: index, tempDir: snapshot.tempDir))
        }
        await finalize()
    }

    private func pull(devicePath: String, index: Int, tempDir: URL) -> Task<URL?, Never> {
        let destination = tempDir.appendingPathComponent("seg\(index).mp4")
        return Task { [service] in
            do {
                try await service.download(devicePath: devicePath, to: destination)
                return destination
            } catch {
                return nil
            }
        }
    }

    /// Follows the touchscreen with getevent so physical touches land in the video too — Android
    /// itself never renders them for screenrecord on many devices.
    private func startTouchCapture() {
        let service = service
        touchTask = Task { [weak self] in
            guard let info = await service.touchscreen(),
                  let screen = await service.screenSize(),
                  let offset = await service.bootOffset() else { return }
            let parser = TouchEventParser(
                config: .init(panelMaxX: info.maxX, panelMaxY: info.maxY, screenWidth: screen.width, screenHeight: screen.height),
                bootOffset: offset
            )
            var buffer = ""
            do {
                for try await chunk in service.touchStream(device: info.path) {
                    guard !Task.isCancelled else { return }
                    buffer += String(decoding: chunk, as: UTF8.self)
                    // Chunks can split mid-line; process only up to the last full line (CRLF included).
                    guard let lastNewline = buffer.rangeOfCharacter(from: .newlines, options: .backwards) else { continue }
                    let complete = String(buffer[...lastNewline.upperBound])
                    buffer = String(buffer[lastNewline.upperBound...])
                    guard let self else { return }
                    self.session?.touchEvents.append(contentsOf: parser.parse(chunk: complete))
                }
            } catch { /* device stream ended; keep whatever was captured */ }
        }
    }

    /// Mirror gestures (mouse on the Mac) reported by the mirror view while recording.
    func appendMirrorTouch(from: (Int, Int), to: (Int, Int)) {
        guard isRecording, session != nil else { return }
        let travel = hypot(Double(to.0 - from.0), Double(to.1 - from.1))
        let kind: TouchEvent.Kind = travel <= 24
            ? .tap(x: Double(to.0), y: Double(to.1))
            : .swipe(points: [(Double(from.0), Double(from.1)), (Double(to.0), Double(to.1))])
        session?.touchEvents.append(TouchEvent(timestamp: Date(), kind: kind))
    }

    private func finalize() async {
        guard let snapshot = session else { return }
        stopTicker()
        touchTask?.cancel(); touchTask = nil
        phase = .saving

        var segments: [URL] = []
        for pull in snapshot.pulls {
            if let url = await pull.value { segments.append(url) }
        }
        cleanupDeviceFiles(snapshot)

        if snapshot.failed && segments.isEmpty {
            finish(.failed("Recording failed — screenrecord stopped unexpectedly."))
            return
        }
        guard !segments.isEmpty else {
            finish(.failed("No video was captured."))
            return
        }

        var clips = segments
        var merged = false
        if clips.count > 1 {
            let output = snapshot.tempDir.appendingPathComponent("recording.mp4")
            do {
                try await ScreenRecordingStitcher.stitch(segments: clips, to: output)
                clips = [output]
                merged = true
            } catch {
                // e.g. the device rotated between segments — keep the clips instead of losing them.
            }
        }

        // Burn touch markers into the video (physical + mirrored); cosmetic, so a failure keeps the clean video.
        if !snapshot.touchEvents.isEmpty, clips.count == 1 {
            let marked = snapshot.tempDir.appendingPathComponent("marked.mp4")
            do {
                try await TouchMarkerRenderer.render(
                    events: snapshot.touchEvents,
                    into: clips[0],
                    recordingStart: snapshot.startedAt,
                    to: marked
                )
                clips = [marked]
            } catch { }
        }

        presentSavePanel(clips: clips, merged: merged, tempDir: snapshot.tempDir, startedAt: snapshot.startedAt)
    }

    /// Deletes the device-side copies; local temp files go away after save/discard.
    private func cleanupDeviceFiles(_ snapshot: Session) {
        let paths = snapshot.completedDevicePaths + (snapshot.currentDevicePath.map { [$0] } ?? [])
        guard !paths.isEmpty else { return }
        let service = service
        Task.detached {
            for path in paths { await service.remove(devicePath: path) }
        }
    }

    // MARK: - Saving

    private func presentSavePanel(clips: [URL], merged: Bool, tempDir: URL, startedAt: Date) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = ScreenRecordingService.defaultFileName(model: deviceName, date: startedAt)
        panel.message = "Choose where to save the recording"
        guard panel.runModal() == .OK, let target = panel.url else {
            try? FileManager.default.removeItem(at: tempDir)
            finish(.discarded)
            return
        }
        do {
            let saved = try write(clips: clips, to: target)
            NSWorkspace.shared.activateFileViewerSelecting(saved)
            finish(merged || saved.count == 1
                ? .saved(fileNames: saved.map(\.lastPathComponent))
                : .savedMultipleClips(fileNames: saved.map(\.lastPathComponent)))
        } catch {
            finish(.failed("Could not save the recording: \(error.localizedDescription)"))
        }
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Copies the clips to the chosen location; extra clips (rotation fallback) are numbered.
    private func write(clips: [URL], to target: URL) throws -> [URL] {
        var saved: [URL] = []
        for (index, clip) in clips.enumerated() {
            let destination = index == 0 ? target : numberedSibling(of: target, index: index + 1)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: clip, to: destination)
            saved.append(destination)
        }
        return saved
    }

    private func numberedSibling(of url: URL, index: Int) -> URL {
        let stem = url.deletingPathExtension().lastPathComponent
        let fileExtension = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
        return url.deletingLastPathComponent().appendingPathComponent("\(stem)-\(index).\(fileExtension)")
    }

    // MARK: - UI helpers

    private func finish(_ result: Status) {
        status = result
        session = nil
        sessionTask = nil
        phase = .idle
        elapsed = 0
        statusClearTask?.cancel()
        statusClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.status = nil
        }
    }

    private func startTicker() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, case .recording(let started) = self.phase else { return }
                self.elapsed = Date().timeIntervalSince(started)
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }
}
