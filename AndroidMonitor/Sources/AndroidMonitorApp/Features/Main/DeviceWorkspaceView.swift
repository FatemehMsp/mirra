import SwiftUI

struct DeviceWorkspaceView: View {
    let device: AndroidDevice
    @AppStorage("mirrorEnabled") private var mirrorEnabled = true
    @StateObject private var installer: DropInstaller
    @ObservedObject private var recorder: ScreenRecorder

    init(device: AndroidDevice) {
        self.device = device
        _installer = StateObject(wrappedValue: DropInstaller(serial: device.serial))
        _recorder = ObservedObject(
            wrappedValue: ScreenRecorderStore.shared.recorder(for: device.serial, deviceName: device.model ?? device.serial)
        )
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(device.model ?? device.serial).font(.headline)
                        Text(device.serial).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    DeviceKeyButton(icon: "chevron.backward", help: "Back", code: 4, tint: Theme.accent, serial: device.serial)
                    DeviceKeyButton(icon: "circle", help: "Home", code: 3, tint: Theme.accent2, serial: device.serial)
                    DeviceKeyButton(icon: "square.on.square", help: "Recents", code: 187, tint: .purple, serial: device.serial)
                    DeviceKeyButton(icon: "power", help: "Power", code: 26, tint: .orange, serial: device.serial)
                    Divider().frame(height: 18).padding(.horizontal, 2)
                    IconButton(icon: mirrorEnabled ? "eye.fill" : "eye.slash.fill", help: mirrorEnabled ? "Mirror on (click to turn off and save memory)" : "Mirror off (click to turn on)", tint: mirrorEnabled ? Theme.accent : .gray) { mirrorEnabled.toggle() }
                    IconButton(icon: "camera.fill", help: "Screenshot", tint: Theme.accent2) { DeviceActions.screenshot(serial: device.serial) }
                    RecordingQualityMenu(recorder: recorder)
                    RecordingControls(recorder: recorder)
                    RecordingStatusView(recorder: recorder)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.bar)
                Divider()
                ZStack {
                    Theme.backdrop
                    if mirrorEnabled {
                        H264MirrorView(serial: device.serial)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.18), lineWidth: 2))
                            .shadow(color: Theme.accent.opacity(0.25), radius: 24)
                            .padding(18)
                    } else {
                        ContentUnavailableView {
                            Label("Mirror is off", systemImage: "eye.slash")
                        } description: {
                            Text("Files, Apps, Logcat and Shell still work. Turning the mirror off saves memory and CPU.")
                        } actions: {
                            Button("Turn on Mirror") { mirrorEnabled = true }.buttonStyle(.borderedProminent)
                        }
                    }
                }
                // Recording runs on the device, so the badge must show even with the mirror off.
                .overlay(alignment: .topLeading) {
                    if recorder.isRecording {
                        RecBadge(elapsed: recorder.elapsed).padding(26)
                    }
                }
            }
            .frame(minWidth: 380, idealWidth: 460)
            InspectorPanels(serial: device.serial)
                .frame(minWidth: 420)
        }
        .onDrop(of: [.fileURL], isTargeted: $installer.targeted) { installer.accept($0) }
        .overlay { DropOverlay(installer: installer) }
    }
}

private struct IconButton: View {
    let icon: String
    let help: String
    var tint: Color = .primary
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(tint).frame(width: 30, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Quality picker for the next recording; the running recording keeps the quality it started with.
private struct RecordingQualityMenu: View {
    @ObservedObject var recorder: ScreenRecorder

    var body: some View {
        Menu {
            ForEach(ScreenRecordingService.Quality.allCases) { quality in
                Button {
                    recorder.quality = quality
                } label: {
                    if quality == recorder.quality {
                        Label(quality.label, systemImage: "checkmark")
                    } else {
                        Text(quality.label)
                    }
                }
            }
        } label: {
            Text(recorder.quality.shortLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(recorder.isRecording ? Color.secondary.opacity(0.5) : Color.secondary)
                .frame(minWidth: 42, minHeight: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.06)))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(recorder.isRecording)
        .help(recorder.isRecording
            ? "Quality is locked while recording"
            : "Video quality (bit rate). Lower bit rates produce much smaller files.")
    }
}

/// Toolbar control for video recording: record button, live REC indicator + stop, or saving state.
private struct RecordingControls: View {
    @ObservedObject var recorder: ScreenRecorder

    var body: some View {
        switch recorder.phase {
        case .idle:
            IconButton(icon: "record.circle", help: "Record video", tint: .red) { recorder.start() }
        case .recording:
            HStack(spacing: 6) {
                PulsingRedDot()
                Text("REC \(ScreenRecordingService.elapsedLabel(recorder.elapsed))")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.red)
                    .fixedSize()
                IconButton(icon: "stop.circle.fill", help: "Stop recording", tint: .red) { recorder.stop() }
            }
        case .saving:
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text("Saving…").font(.caption).foregroundStyle(.secondary).fixedSize()
            }
        }
    }
}

/// Result of the last recording, shown next to the record button; auto-clears after a few seconds.
private struct RecordingStatusView: View {
    @ObservedObject var recorder: ScreenRecorder

    var body: some View {
        if let status = recorder.status {
            switch status {
            case .saved(let names):
                Label(names.joined(separator: ", "), systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green).lineLimit(1).help("Saved to your chosen folder")
            case .savedMultipleClips(let names):
                Label("\(names.count) clips saved (device rotated)", systemImage: "film.stack")
                    .font(.caption).foregroundStyle(.orange).lineLimit(1)
                    .help("The device rotated during recording, so the clips were saved separately: \(names.joined(separator: ", "))")
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).lineLimit(1)
            case .discarded:
                Label("Recording discarded", systemImage: "trash")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// Red pulsing dot used in the toolbar and the on-screen REC badge.
private struct PulsingRedDot: View {
    @State private var pulse = false

    var body: some View {
        Circle().fill(.red).frame(width: 8, height: 8)
            .opacity(pulse ? 0.25 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
            }
    }
}

/// Camcorder-style badge over the mirrored screen while a recording is in progress.
private struct RecBadge: View {
    let elapsed: TimeInterval

    var body: some View {
        HStack(spacing: 7) {
            PulsingRedDot()
            Text("REC \(ScreenRecordingService.elapsedLabel(elapsed))")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule(style: .continuous).fill(Color.black.opacity(0.55)))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.red.opacity(0.7), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 4)
        .allowsHitTesting(false)
    }
}

private struct DeviceKeyButton: View {
    let icon: String
    let help: String
    let code: Int
    let tint: Color
    let serial: String
    var body: some View {
        IconButton(icon: icon, help: help, tint: tint) {
            Task {
                let adb = ADBClient(adbURL: AppADB.url)
                _ = try? await adb.run(serial: serial, arguments: ["shell", "input", "keyevent", "\(code)"], timeout: .seconds(5))
            }
        }
    }
}
