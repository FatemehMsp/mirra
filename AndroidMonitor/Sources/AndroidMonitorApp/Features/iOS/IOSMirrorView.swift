import AVFoundation
import CoreMediaIO
import SwiftUI

/// Live screen of an iPhone / iPad connected by cable, the same feed QuickTime uses.
/// Touch control (opt-in, through WebDriverAgent) turns clicks into taps when enabled.
struct IOSMirrorView: View {
    @ObservedObject var model: IOSMirrorModel
    @ObservedObject var input: IOSInputController

    var body: some View {
        ZStack {
            Theme.backdrop
            if model.running {
                IOSPreview(session: model.session, input: input, onUncontrolledClick: { model.showViewOnlyHint() })
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.18), lineWidth: 2))
                    .shadow(color: Theme.accent.opacity(0.25), radius: 24)
                    .padding(18)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "iphone.gen3.radiowaves.left.and.right").font(.system(size: 40)).foregroundStyle(Theme.gradient)
                    Text(model.status).font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 280)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.showViewOnlyHint() }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}

@MainActor
final class IOSMirrorModel: ObservableObject {
    @Published var running = false
    @Published var status = "Connect the iPhone with a cable, unlock it and tap Trust."
    @Published var isRecording = false
    @Published var notice: String?
    let session = AVCaptureSession()
    private let udid: String
    private var poll: Task<Void, Never>?
    private let grabber = FrameGrabber()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let recorder = RecordingDelegate()
    private var noticeTask: Task<Void, Never>?

    init(udid: String) {
        self.udid = udid
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(grabber, queue: DispatchQueue(label: "ios-mirror-frames"))
        session.beginConfiguration()
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
    }

    // MARK: Screenshot and recording

    func snapshot() -> NSImage? { grabber.image() }

    func saveScreenshot() {
        guard let image = snapshot(), let png = NSBitmapImageRep(data: image.tiffRepresentation ?? Data())?.representation(using: .png, properties: [:]) else {
            show("No frame yet. Wait until the screen appears."); return
        }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = CaptureName.file(prefix: "ios-screenshot", fileExtension: "png", date: .now)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try png.write(to: url, options: .atomic); show("Saved \(url.lastPathComponent)") } catch { show(error.localizedDescription) }
    }

    func copyScreenshot() {
        guard let image = snapshot() else { show("No frame yet. Wait until the screen appears."); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        show("Screenshot copied. Paste it anywhere with ⌘V.")
    }

    func toggleRecording() {
        if isRecording { movieOutput.stopRecording(); return }
        guard running else { show("No screen to record yet."); return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.quickTimeMovie]; panel.nameFieldStringValue = CaptureName.file(prefix: "ios-recording", fileExtension: "mov", date: .now)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? FileManager.default.removeItem(at: url)
        if !session.outputs.contains(movieOutput) {
            session.beginConfiguration()
            if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
            session.commitConfiguration()
        }
        recorder.onFinish = { [weak self] error, url in
            Task { @MainActor in
                self?.isRecording = false
                self?.show(error == nil ? "Saved \(url.lastPathComponent)" : "Recording failed: \(error!.localizedDescription)")
            }
        }
        movieOutput.startRecording(to: url, recordingDelegate: recorder)
        isRecording = true
        show("Recording… press the stop button to finish.")
    }

    /// When touch control is off, clicking the mirrored screen explains the options instead of doing nothing.
    func showViewOnlyHint() {
        show("View-only right now: click the hand button to enable touch control, or use Universal Control (Settings → General → AirPlay & Continuity) to drive the phone with your Mac's mouse and keyboard.")
    }

    private func show(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { try? await Task.sleep(for: .seconds(5)); if !Task.isCancelled { notice = nil } }
    }

    func start() {
        Self.allowScreenCaptureDevices()
        poll = Task {
            status = "Waiting for Camera permission… allow it in the system dialog."
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                status = "Camera access is needed to show the iPhone screen. Allow it in System Settings → Privacy & Security → Camera."
                return
            }
            while !Task.isCancelled {
                if !running, let capture = findDevice(), let input = try? AVCaptureDeviceInput(device: capture), session.canAddInput(input) {
                    session.beginConfiguration(); session.addInput(input); session.commitConfiguration()
                    session.startRunning()
                    running = true
                } else if !running {
                    status = "Waiting for the iPhone screen… unlock the phone and keep the cable connected. (Cable only: Wi‑Fi devices cannot be mirrored.)"
                }
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    func stop() {
        poll?.cancel(); poll = nil
        if movieOutput.isRecording { movieOutput.stopRecording() }
        if session.isRunning { session.stopRunning() }
        session.inputs.forEach { session.removeInput($0) }
        running = false
    }

    private func findDevice() -> AVCaptureDevice? {
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed, position: .unspecified).devices
        return found.first { $0.uniqueID.caseInsensitiveCompare(udid) == .orderedSame }
            ?? (found.count == 1 ? found.first : nil)
    }

    /// Makes iOS screens show up as capture devices (what QuickTime does when you pick the iPhone as a camera).
    private static func allowScreenCaptureDevices() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &allow)
    }
}

private struct IOSPreview: NSViewRepresentable {
    let session: AVCaptureSession
    let input: IOSInputController
    /// Called for clicks that cannot be sent to the device (touch control off).
    let onUncontrolledClick: () -> Void

    func makeNSView(context: Context) -> IOSMirrorSurfaceView {
        let view = IOSMirrorSurfaceView()
        view.attach(session: session, input: input, onUncontrolledClick: onUncontrolledClick)
        return view
    }
    func updateNSView(_ nsView: IOSMirrorSurfaceView, context: Context) {
        nsView.attach(session: session, input: input, onUncontrolledClick: onUncontrolledClick)
    }
}

/// The preview layer plus mouse routing. Points are converted to video-normalized coordinates
/// via the layer itself (so aspect-fit letterboxing is handled), then scaled to screen points.
final class IOSMirrorSurfaceView: NSView {
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private weak var input: IOSInputController?
    private var onUncontrolledClick: (() -> Void)?
    private var downPoint: CGPoint?
    private var downTime: TimeInterval = 0

    func attach(session: AVCaptureSession, input: IOSInputController, onUncontrolledClick: @escaping () -> Void) {
        self.input = input
        self.onUncontrolledClick = onUncontrolledClick
        guard previewLayer?.session !== session else { return }
        wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        self.layer = layer
        previewLayer = layer
    }

    override func layout() {
        super.layout()
        previewLayer?.frame = bounds
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Maps a view point to screen points: the video is the screen, so aspect-fit letterboxing
    /// plus the WDA-reported screen size are all the math needed.
    private func screenPoint(_ point: CGPoint) -> (x: Double, y: Double)? {
        guard let input, let layer = previewLayer, input.screenSize.width > 0, input.screenSize.height > 0,
              layer.bounds.width > 0, layer.bounds.height > 0 else { return nil }
        let bounds = layer.bounds
        let aspect = CGFloat(input.screenSize.width / input.screenSize.height)
        let fitHeight = min(bounds.width / aspect, bounds.height)
        let contentWidth = aspect * fitHeight
        let originX = (bounds.width - contentWidth) / 2
        let originY = (bounds.height - fitHeight) / 2
        guard point.x >= originX, point.x <= originX + contentWidth,
              point.y >= originY, point.y <= originY + fitHeight else { return nil }
        let normalizedX = (point.x - originX) / contentWidth
        let normalizedY = (point.y - originY) / fitHeight
        return (Double(normalizedX * CGFloat(input.screenSize.width)), Double(normalizedY * CGFloat(input.screenSize.height)))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        downPoint = convert(event.locationInWindow, from: nil)
        downTime = event.timestamp
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = downPoint else { return }
        downPoint = nil
        guard let input else { return }
        let end = convert(event.locationInWindow, from: nil)
        // Without touch control the click cannot reach the device — explain the options instead.
        guard input.isReady else {
            onUncontrolledClick?()
            return
        }
        guard let from = screenPoint(start), let to = screenPoint(end) else { return }
        if hypot(to.x - from.x, to.y - from.y) > 14 {
            input.drag(from: from, to: to, durationMs: max(80, min(Int((event.timestamp - downTime) * 1000), 1500)))
        } else {
            input.tap(x: to.x, y: to.y)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let input, input.isReady, event.deltaY != 0 else { return }
        let position = convert(event.locationInWindow, from: nil)
        guard let point = screenPoint(position) else { return }
        input.scroll(x: point.x, y: point.y, delta: Double(event.deltaY))
    }
}

/// Keeps the newest frame so a screenshot can be taken at any moment.
private final class FrameGrabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private var latest: CVImageBuffer?
    private let lock = NSLock()
    private let context = CIContext()

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock(); latest = buffer; lock.unlock()
    }

    func image() -> NSImage? {
        lock.lock(); let buffer = latest; lock.unlock()
        guard let buffer else { return nil }
        let ci = CIImage(cvImageBuffer: buffer)
        guard let cg = context.createCGImage(ci, from: ci.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

private final class RecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    var onFinish: (@Sendable (Error?, URL) -> Void)?
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        onFinish?(error, outputFileURL)
    }
}
