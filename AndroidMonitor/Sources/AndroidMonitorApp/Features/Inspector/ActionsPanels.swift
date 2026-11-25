import AppKit
import SwiftUI

/// One-click QA panel: app data and permissions, quick device settings, Unicode typing
/// and the crash ring-buffer recorder.
struct ActionsPanel: View {
    let serial: String
    @ObservedObject var unicode: UnicodeTypingModel
    @ObservedObject var crashRecorder: CrashRecorder
    @State private var status = ""
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AppSection(serial: serial, status: $status, busy: $busy)
                PermissionsSection(serial: serial, status: $status, busy: $busy)
                DeviceSection(serial: serial, status: $status, busy: $busy)
                TypingSection(unicode: unicode)
                CrashSection(recorder: crashRecorder)
                if !status.isEmpty {
                    Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .padding(12)
        }
    }
}

// MARK: - App data

private struct AppSection: View {
    let serial: String
    @Binding var status: String
    @Binding var busy: Bool
    @State private var package = ""

    var body: some View {
        GroupBox("App") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Package ID (e.g. com.example.app)", text: $package)
                    .textFieldStyle(.roundedBorder)
                Button("Clear Data") {
                    run {
                        try await AppActionsService(adb: ADBClient(adbURL: AppADB.url), serial: serial).clearData(package: package)
                    }
                }
                .disabled(package.isEmpty || busy)
            }
        }
    }

    private func run(_ work: @escaping @Sendable () async throws -> Void) {
        busy = true
        status = ""
        Task {
            do {
                try await work()
                status = "Done."
            } catch {
                status = "Error: \(error.localizedDescription)"
            }
            busy = false
        }
    }
}

// MARK: - Permissions

private struct PermissionsSection: View {
    let serial: String
    @Binding var status: String
    @Binding var busy: Bool
    @State private var package = ""
    @State private var permissions: [PermissionsService.Permission] = []

    private var service: PermissionsService {
        PermissionsService(adb: ADBClient(adbURL: AppADB.url), serial: serial)
    }

    var body: some View {
        GroupBox("Permissions") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Package ID", text: $package)
                        .textFieldStyle(.roundedBorder)
                    Button("Load") { load() }
                        .disabled(package.isEmpty || busy)
                }
                if !permissions.isEmpty {
                    Text("\(permissions.filter(\.granted).count) of \(permissions.count) granted").font(.caption).foregroundStyle(.secondary)
                    ForEach(permissions) { permission in
                        Toggle(permission.name.replacingOccurrences(of: "android.permission.", with: ""), isOn: binding(permission))
                            .font(.system(size: 11))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        Button("Grant All") { run { try await service.grantAll(package: package) } }.disabled(busy)
                        Button("Revoke All") { run { try await service.revokeAll(package: package) } }.disabled(busy)
                    }
                }
            }
        }
    }

    private func load() {
        busy = true
        status = ""
        Task {
            do {
                permissions = try await service.list(package: package)
                if permissions.isEmpty { status = "No runtime permissions found for \(package)." }
            } catch {
                status = "Error: \(error.localizedDescription)"
            }
            busy = false
        }
    }

    private func run(_ work: @escaping @Sendable () async throws -> Void) {
        busy = true
        Task {
            do {
                try await work()
                load()
            } catch {
                status = "Error: \(error.localizedDescription)"
            }
            busy = false
        }
    }

    private func binding(_ permission: PermissionsService.Permission) -> Binding<Bool> {
        Binding(
            get: { permission.granted },
            set: { newValue in
                Task {
                    do {
                        if newValue {
                            try await service.grant(package: package, permission: permission.name)
                        } else {
                            try await service.revoke(package: package, permission: permission.name)
                        }
                        load()
                    } catch {
                        status = "Error: \(error.localizedDescription)"
                        load()
                    }
                }
            }
        )
    }
}

// MARK: - Device settings

private struct DeviceSection: View {
    let serial: String
    @Binding var status: String
    @Binding var busy: Bool

    private static let locales = ["en-US", "en-GB", "fa-IR", "ar-SA", "de-DE", "tr-TR"]
    @State private var locale = "en-GB"
    @State private var fontScale = 1.0
    @State private var animationScale = 1.0
    @State private var rotation = 0
    @State private var density = 420
    @State private var width = 1080
    @State private var height = 2400
    @State private var autoRotate = false

    private var service: DeviceSettingsService {
        DeviceSettingsService(adb: ADBClient(adbURL: AppADB.url), serial: serial)
    }

    var body: some View {
        GroupBox("Device") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Picker("Language", selection: $locale) {
                        ForEach(Self.locales, id: \.self) { Text($0) }
                    }
                    Button("Apply") { run { try await service.setLocale(locale) } }.disabled(busy)
                }
                HStack(spacing: 8) {
                    Text("Font scale").font(.caption).frame(width: 90, alignment: .leading)
                    Slider(value: $fontScale, in: 0.85...1.3, step: 0.05)
                    Text(String(format: "%.2f", fontScale)).font(.caption.monospacedDigit()).frame(width: 36)
                    Button("Apply") { run { try await service.setFontScale(fontScale) } }.disabled(busy)
                }
                HStack(spacing: 8) {
                    Text("Animation").font(.caption).frame(width: 90, alignment: .leading)
                    Slider(value: $animationScale, in: 0...2, step: 0.25)
                    Text(String(format: "%.2f", animationScale)).font(.caption.monospacedDigit()).frame(width: 36)
                    Button("Apply") { run { try await service.setAnimationScale(animationScale) } }.disabled(busy)
                }
                HStack(spacing: 8) {
                    Picker("Rotation", selection: $rotation) {
                        Text("Portrait").tag(0)
                        Text("Landscape").tag(1)
                        Text("Rev. portrait").tag(2)
                        Text("Rev. landscape").tag(3)
                    }
                    Toggle("Auto-rotate", isOn: $autoRotate)
                        .controlSize(.small)
                        .onChange(of: autoRotate) { enabled in
                            run { try await service.setAutoRotate(enabled) }
                        }
                    Button("Set") {
                        run {
                            try await service.setAutoRotate(false)
                            try await service.setRotation(rotation)
                        }
                    }.disabled(busy || autoRotate)
                }
                HStack(spacing: 8) {
                    Button("Wi-Fi off") { run { try await service.setWiFi(false) } }.disabled(busy)
                    Button("Wi-Fi on") { run { try await service.setWiFi(true) } }.disabled(busy)
                    Button("Data off") { run { try await service.setCellularData(false) } }.disabled(busy)
                    Button("Data on") { run { try await service.setCellularData(true) } }.disabled(busy)
                    Button("Airplane") { run { try await service.setAirplaneMode(true) } }.disabled(busy)
                }
                HStack(spacing: 8) {
                    TextField("DPI", value: $density, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).frame(width: 60)
                    Button("Set") { run { try await service.setDensity(density) } }.disabled(busy)
                    Button("Reset") { run { try await service.resetDensity() } }.disabled(busy)
                }
                HStack(spacing: 8) {
                    TextField("W", value: $width, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).frame(width: 60)
                    TextField("H", value: $height, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).frame(width: 60)
                    Button("Set size") { run { try await service.setScreenSize(width, height) } }.disabled(busy)
                    Button("Reset size") { run { try await service.resetScreenSize() } }.disabled(busy)
                }
            }
        }
    }

    private func run(_ work: @escaping @Sendable () async throws -> Void) {
        busy = true
        status = ""
        Task {
            do {
                try await work()
                status = "Done."
            } catch {
                status = "Error: \(error.localizedDescription)"
            }
            busy = false
        }
    }
}

// MARK: - Typing

private struct TypingSection: View {
    @ObservedObject var unicode: UnicodeTypingModel

    var body: some View {
        GroupBox("Typing") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Type from your Mac's keyboard into the device, including Persian and emoji, through the ADBKeyboard IME. While enabled the device uses the Mirra keyboard.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if unicode.busy { ProgressView().controlSize(.small) }
                    Button(unicode.enabled ? "Disable Unicode Typing" : "Enable Unicode Typing") { unicode.toggle() }
                        .disabled(unicode.busy)
                }
                if let status = unicode.status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Crash recording

private struct CrashSection: View {
    @ObservedObject var recorder: CrashRecorder

    var body: some View {
        GroupBox("Crash recording") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Keeps the last \(Int(CrashRecorder.bufferSeconds / 60)) minutes of the screen in a rolling buffer. When a crash or ANR is detected, the window is saved automatically to Downloads and recording re-arms.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button(recorder.armed ? "Disarm" : "Arm crash recording") { recorder.toggle() }
                    if recorder.armed {
                        Label("Armed", systemImage: "record.circle")
                            .font(.caption.weight(.semibold)).foregroundStyle(.red)
                    }
                }
                if case .failed(let message) = recorder.state {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }
}

/// Saved deep links plus a launch history, per device.
struct DeepLinksPanel: View {
    @ObservedObject var store: DeepLinkStore
    @State private var url = ""
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("Deep link URL", text: $url)
                    .textFieldStyle(.roundedBorder)
                Button("Launch") {
                    guard !url.isEmpty else { return }
                    store.launch(url)
                }
                .disabled(url.isEmpty)
            }
            HStack(spacing: 8) {
                TextField("Name (optional)", text: $name)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    guard !url.isEmpty else { return }
                    store.add(name: name, url: url)
                    name = ""; url = ""
                }
                .disabled(url.isEmpty)
            }

            if !store.links.isEmpty {
                Text("Saved").font(.headline).padding(.top, 4)
                ForEach(store.links) { link in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(link.name).font(.body)
                            Text(link.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Launch") { store.launch(link.url) }
                        Button(role: .destructive) { store.remove(id: link.id) } label: { Image(systemName: "trash") }
                    }
                }
            }

            if !store.recent.isEmpty {
                Text("Recent").font(.headline).padding(.top, 4)
                ForEach(store.recent, id: \.self) { item in
                    Button {
                        url = item
                        store.launch(item)
                    } label: {
                        Text(item).lineLimit(1).truncationMode(.middle).font(.caption)
                    }
                    .buttonStyle(.link)
                }
            }
            Spacer()
        }
        .padding(12)
    }
}
