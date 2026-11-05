import AVFoundation
import CoreMediaIO
import SwiftUI

/// Live, view-only screen of an iPhone / iPad connected by cable, the same feed QuickTime uses.
/// iOS does not allow remote touch or keyboard input, so this view only displays.
struct IOSMirrorView: View {
    let device: IOSDevice
    @StateObject private var model: IOSMirrorModel

    init(device: IOSDevice) {
        self.device = device
        _model = StateObject(wrappedValue: IOSMirrorModel(udid: device.udid))
    }

    var body: some View {
        ZStack {
            Theme.backdrop
            if model.running {
                IOSPreview(session: model.session)
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
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}

@MainActor
final class IOSMirrorModel: ObservableObject {
    @Published var running = false
    @Published var status = "Connect the iPhone with a cable, unlock it and tap Trust."
    let session = AVCaptureSession()
    private let udid: String
    private var poll: Task<Void, Never>?

    init(udid: String) { self.udid = udid }

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
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        view.layer = layer
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
