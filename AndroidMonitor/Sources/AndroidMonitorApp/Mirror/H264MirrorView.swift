import AVFoundation
import CoreMedia
import SwiftUI

struct H264MirrorView: NSViewRepresentable {
    let serial: String

    func makeCoordinator() -> Coordinator { Coordinator(serial: serial) }

    func makeNSView(context: Context) -> MirrorSurfaceView {
        let view = MirrorSurfaceView()
        context.coordinator.start(surface: view)
        let coordinator = context.coordinator
        view.onGesture = { [weak coordinator] from, to, duration, size in
            coordinator?.gesture(from: from, to: to, duration: duration, viewSize: size)
        }
        view.onVisibilityChange = { [weak coordinator] in coordinator?.setPaused(!$0) }
        view.onKeyEvents = { [weak coordinator] in coordinator?.input.keyEvents($0) }
        view.onText = { [weak coordinator] in coordinator?.input.type($0) }
        view.onShortcut = { [weak coordinator] in coordinator?.shortcut($0) ?? false }
        view.onScroll = { [weak coordinator] point, delta, size in coordinator?.scroll(at: point, delta: delta, viewSize: size) }
        return view
    }

    func updateNSView(_ nsView: MirrorSurfaceView, context: Context) {}
    static func dismantleNSView(_ nsView: MirrorSurfaceView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor
    final class Coordinator {
        private let serial: String
        private let adb = ADBClient(adbURL: AppADB.url)
        private var task: Task<Void, Never>?
        private var screenshotTask: Task<Void, Never>?
        let input: RemoteInput
        private let clipboard: PhoneClipboard
        private var frameCount = 0
        private var parser = AnnexBParser()
        private let builder = H264SampleBufferBuilder()
        private var flushTask: Task<Void, Never>?
        private var clipboardSync: Task<Void, Never>?
        private var lastPhoneClipboard: String?

        /// Mirrors whatever is copied on the phone (long-press > Copy, or Cmd+C) into the Mac clipboard.
        private func startClipboardSync() {
            clipboardSync = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    if let text = await self.clipboard.get() {
                        if self.lastPhoneClipboard == nil { self.lastPhoneClipboard = text }
                        else if text != self.lastPhoneClipboard {
                            self.lastPhoneClipboard = text
                            if !text.isEmpty {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(text, forType: .string)
                            }
                        }
                    }
                    try? await Task.sleep(for: .milliseconds(self.paused ? 3000 : 600))
                }
            }
        }

        private func display(_ units: [Data], on displayLayer: AVSampleBufferDisplayLayer) {
            for data in units {
                guard let sample = builder.consume(data) else { continue }
                if displayLayer.status == .failed { displayLayer.flush() }
                displayLayer.enqueue(sample)
                frameCount += 1
            }
        }
        private var deviceSize = CGSize(width: 1080, height: 2400)

        init(serial: String) { self.serial = serial; self.input = RemoteInput(serial: serial); self.clipboard = PhoneClipboard(serial: serial) }

        private var displayLayer: AVSampleBufferDisplayLayer?
        private(set) var paused = false

        private func startVideo() {
            guard task == nil, let displayLayer else { return }
        task = Task { [adb, serial] in
            while !Task.isCancelled {
                self.parser = AnnexBParser()
                do {
                    let stream = adb.stream(serial: serial, arguments: [
                        "exec-out", "screenrecord", "--output-format=h264",
                        "--size", "576x1280", "--bit-rate", "3500000", "--time-limit", "180", "-"
                    ])
                    for try await chunk in stream {
                        guard !Task.isCancelled else { return }
                        flushTask?.cancel()
                        display(parser.append(chunk), on: displayLayer)
                        // screenrecord only emits on screen change, so the parser would hold the newest frame
                        // until the next one arrives; flush it once the pipe goes quiet.
                        flushTask = Task { [weak self] in
                            try? await Task.sleep(for: .milliseconds(30))
                            guard !Task.isCancelled, let self else { return }
                            self.display(self.parser.finishTrailingUnit(), on: displayLayer)
                        }
                    }
                } catch { }
                if !Task.isCancelled { try? await Task.sleep(for: .milliseconds(500)) }
            }
        }
        }

        /// Stops the screenrecord/decoder while the window is hidden or covered, so a busy machine is not charged for a stream nobody sees.
        func setPaused(_ pause: Bool) {
            guard pause != paused else { return }
            paused = pause
            if pause {
                task?.cancel(); task = nil; flushTask?.cancel()
            } else {
                displayLayer?.flushAndRemoveImage()
                startVideo()
            }
        }

        func start(surface: MirrorSurfaceView) {
            startClipboardSync()
            let displayLayer = surface.displayLayer
            self.displayLayer = displayLayer
            Task { [adb, serial] in
                if let out = try? await adb.run(serial: serial, arguments: ["shell", "wm", "size"], timeout: .seconds(5)).stdout,
                   let line = String(decoding: out, as: UTF8.self).split(separator: "\n").last(where: { $0.contains("x") }),
                   let dims = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces).split(separator: "x"),
                   dims.count == 2, let w = Double(dims[0]), let h = Double(dims[1]) {
                    self.deviceSize = CGSize(width: w, height: h)
                }
            }
            startVideo()
            screenshotTask = Task { [adb, serial] in
                try? await Task.sleep(for: .seconds(3))
                while !Task.isCancelled {
                    if await self.frameCount > 0 { try? await Task.sleep(for: .seconds(1)); continue }
                    if let result = try? await adb.run(
                        serial: serial,
                        arguments: ["exec-out", "screencap", "-p"],
                        timeout: .seconds(5)
                    ), !result.stdout.isEmpty {
                        surface.showScreenshot(result.stdout)
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }

        func stop() {
            task?.cancel(); task = nil; flushTask?.cancel(); clipboardSync?.cancel(); input.stop(); clipboard.stop()
            screenshotTask?.cancel(); screenshotTask = nil
        }

        /// Maps a view point into device pixels, accounting for the aspect-fit letterbox.
        private func devicePoint(_ point: CGPoint, viewSize: CGSize) -> (Int, Int) {
            let scale = min(viewSize.width / deviceSize.width, viewSize.height / deviceSize.height)
            let w = deviceSize.width * scale, h = deviceSize.height * scale
            let originX = (viewSize.width - w) / 2, originY = (viewSize.height - h) / 2
            let x = min(max((point.x - originX) / w, 0), 1) * deviceSize.width
            let y = min(max(1 - (point.y - originY) / h, 0), 1) * deviceSize.height
            return (Int(x), Int(y))
        }

        func gesture(from: CGPoint, to: CGPoint, duration: TimeInterval, viewSize: CGSize) {
            guard viewSize.width > 0, viewSize.height > 0 else { return }
            let (x1, y1) = devicePoint(from, viewSize: viewSize)
            let (x2, y2) = devicePoint(to, viewSize: viewSize)
            // Mark the gesture in the active recording (mouse taps never show up on their own).
            ScreenRecorderStore.shared.recordMirrorTouch(serial: serial, from: (x1, y1), to: (x2, y2))
            if hypot(Double(x2 - x1), Double(y2 - y1)) > 24 {
                input.swipe(x1, y1, x2, y2, durationMs: max(80, min(Int(duration * 1000), 800)))
            } else {
                input.tap(x1, y1)
            }
        }

        /// Cmd+V/C/X/A act on the phone: Mac clipboard is copied into the phone's clipboard before pasting, and the phone's
        /// clipboard is copied back to the Mac after copy/cut. Returns whether the shortcut was consumed.
        func shortcut(_ key: String) -> Bool {
            switch key {
            case "v":
                guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return true }
                Task {
                    if await clipboard.set(text) { lastPhoneClipboard = text; input.keyEvents([279]) } else { input.paste(text) }
                }
            case "c", "x":
                Task {
                    let before = await clipboard.get()
                    input.keyEvents([key == "c" ? 278 : 277])
                    try? await Task.sleep(for: .milliseconds(250))
                    if let after = await clipboard.get(), !after.isEmpty, after != before {
                        lastPhoneClipboard = after
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(after, forType: .string)
                    }
                }
            case "a":
                input.run("input keycombination 113 29")
            default:
                return false
            }
            return true
        }

        private var scrollAccumulator: CGFloat = 0
        private var scrollTask: Task<Void, Never>?

        /// Trackpad / wheel scrolling becomes a short swipe, sent once the wheel pauses.
        func scroll(at point: CGPoint, delta: CGFloat, viewSize: CGSize) {
            scrollAccumulator += delta
            scrollTask?.cancel()
            scrollTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled, let self, abs(self.scrollAccumulator) > 1 else { return }
                let (x, y) = self.devicePoint(point, viewSize: viewSize)
                let travel = Int(max(-self.deviceSize.height * 0.5, min(self.deviceSize.height * 0.5, self.scrollAccumulator * 12)))
                let targetY = min(max(y + travel, 0), Int(self.deviceSize.height))
                self.scrollAccumulator = 0
                ScreenRecorderStore.shared.recordMirrorTouch(serial: self.serial, from: (x, y), to: (x, targetY))
                self.input.swipe(x, y, x, targetY, durationMs: 180)
            }
        }
    }
}

final class MirrorSurfaceView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()
    var onVisibilityChange: ((Bool) -> Void)?
    var onGesture: ((CGPoint, CGPoint, TimeInterval, CGSize) -> Void)?
    var onKeyEvents: (([Int]) -> Void)?
    var onText: ((String) -> Void)?
    var onShortcut: ((String) -> Bool)?
    var onScroll: ((CGPoint, CGFloat, CGSize) -> Void)?

    private var occlusionObserver: NSObjectProtocol?
    private var activeObservers: [NSObjectProtocol] = []
    private var idleTask: Task<Void, Never>?

    /// Visible and app active -> stream; otherwise stop the stream (inactive apps wait 5s so quick Cmd-Tabs do not restart it).
    private func updateVisibility() {
        idleTask?.cancel()
        let visible = window?.occlusionState.contains(.visible) ?? false
        if !visible { onVisibilityChange?(false); return }
        if NSApp.isActive { onVisibilityChange?(true); return }
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.onVisibilityChange?(false)
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        occlusionObserver.map(NotificationCenter.default.removeObserver); occlusionObserver = nil
        guard let window else { return }
        occlusionObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateVisibility() }
        }
        for name in [NSApplication.didResignActiveNotification, NSApplication.didBecomeActiveNotification] {
            activeObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateVisibility() }
            })
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private static let specialKeys: [UInt16: Int] = [
        36: 66, 76: 66, 51: 67, 117: 112, 48: 61, 53: 4,
        123: 21, 124: 22, 125: 20, 126: 19, 115: 122, 119: 123, 116: 92, 121: 93
    ]

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.modifierFlags.contains(.command) else { return false }
        guard !event.modifierFlags.contains(.option), let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        return onShortcut?(key) ?? false
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { return }
        if let code = Self.specialKeys[event.keyCode] { onKeyEvents?([code]); return }
        if event.modifierFlags.contains(.control) { return }
        if let characters = event.characters, !characters.isEmpty { onText?(characters) }
    }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(convert(event.locationInWindow, from: nil), event.scrollingDeltaY, bounds.size)
    }

    override func rightMouseDown(with event: NSEvent) { onKeyEvents?([4]) }
    override func otherMouseDown(with event: NSEvent) { onKeyEvents?([3]) }
    private var downPoint: CGPoint?
    private var downTime: TimeInterval = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); displayLayer.frame = bounds }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); downPoint = convert(event.locationInWindow, from: nil); downTime = event.timestamp }
    override func mouseUp(with event: NSEvent) {
        guard let start = downPoint else { return }
        downPoint = nil
        onGesture?(start, convert(event.locationInWindow, from: nil), event.timestamp - downTime, bounds.size)
    }

    func showScreenshot(_ data: Data) {
        guard let image = NSImage(data: data) else { return }
        layer?.contents = image
    }
}

private final class H264SampleBufferBuilder {
    private var sps: Data?
    private var pps: Data?
    private var format: CMVideoFormatDescription?

    func consume(_ data: Data) -> CMSampleBuffer? {
        guard let unit = H264NALUnit(data: data) else { return nil }
        switch unit.type {
        case .sequenceParameterSet: sps = data; rebuildFormat(); return nil
        case .pictureParameterSet: pps = data; rebuildFormat(); return nil
        case .idrSlice, .nonIDRSlice: return makeSample(data)
        case nil: return nil
        }
    }

    private func rebuildFormat() {
        guard let sps, let pps else { return }
        sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                guard let spsBase = spsBytes.bindMemory(to: UInt8.self).baseAddress,
                      let ppsBase = ppsBytes.bindMemory(to: UInt8.self).baseAddress else { return }
                var pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                var sizes = [sps.count, pps.count]
                pointers.withUnsafeBufferPointer { pointerBuffer in
                    sizes.withUnsafeBufferPointer { sizeBuffer in
                        _ = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &format
                        )
                    }
                }
            }
        }
    }

    private func makeSample(_ nal: Data) -> CMSampleBuffer? {
        guard let format else { return nil }
        var length = UInt32(nal.count).bigEndian
        var payload = Data(bytes: &length, count: 4)
        payload.append(nal)
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: payload.count, flags: 0, blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let block else { return nil }
        payload.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: payload.count) }
        }
        var sample: CMSampleBuffer?
        var size = payload.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let raw = CFArrayGetValueAtIndex(attachments, 0)
            let dictionary = Unmanaged<CFMutableDictionary>.fromOpaque(raw!).takeUnretainedValue()
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sample
    }
}

