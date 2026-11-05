import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class IOSAppsModel: ObservableObject {
    @Published var apps: [IOSApp] = []
    @Published var loading = false
    @Published var message: String?
    private let device: IOSDevice
    private let service = IOSDeviceService()

    init(device: IOSDevice) { self.device = device }

    func load() {
        loading = true; message = nil
        Task {
            defer { loading = false }
            do { apps = try await service.apps(of: device).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
            catch { message = error.localizedDescription }
        }
    }

    func install(_ url: URL) {
        message = "Installing \(url.lastPathComponent)…"
        Task {
            do { try await service.install(url, on: device); message = "Installed \(url.lastPathComponent)"; load() }
            catch { message = "Install failed: \(error.localizedDescription)" }
        }
    }

    func pickIPA() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "ipa") ?? .data]
        if panel.runModal() == .OK, let url = panel.url { install(url) }
    }

    func launch(_ app: IOSApp) {
        Task { do { try await service.launch(app.bundleID, on: device); message = "Launched \(app.name)" } catch { message = error.localizedDescription } }
    }

    func uninstall(_ app: IOSApp) {
        let alert = NSAlert(); alert.messageText = "Uninstall \(app.name)?"; alert.informativeText = app.bundleID; alert.alertStyle = .warning
        alert.addButton(withTitle: "Uninstall"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do { try await service.uninstall(app.bundleID, on: device); apps.removeAll { $0.bundleID == app.bundleID }; message = "Uninstalled \(app.name)" }
            catch { message = error.localizedDescription }
        }
    }
}

struct IOSWorkspaceView: View {
    let device: IOSDevice
    @StateObject private var apps: IOSAppsModel
    @State private var tab = 0
    @State private var query = ""
    @State private var userOnly = true
    @State private var dropTargeted = false

    init(device: IOSDevice) {
        self.device = device
        _apps = StateObject(wrappedValue: IOSAppsModel(device: device))
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.headline)
                    Text("\(device.model) · iOS \(device.osVersion) · \(device.transport == .usb ? "USB" : "Wi‑Fi")").font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.bar)
                Divider()
                IOSMirrorView(device: device)
            }
            .frame(minWidth: 380, idealWidth: 460)

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Picker("", selection: $tab) { Text("Apps").tag(0); Text("Info").tag(1) }.pickerStyle(.segmented).frame(width: 160).labelsHidden()
                    Spacer()
                }
                .padding(10).background(.bar)
                Divider()
                if tab == 0 { appsList } else { info }
            }
            .frame(minWidth: 420)
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url, url.pathExtension.lowercased() == "ipa" { Task { @MainActor in apps.install(url) } }
                }
            }
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(Text("Drop an .ipa to install").font(.title3.weight(.semibold))).padding(14).allowsHitTesting(false)
            }
        }
    }

    private var shown: [IOSApp] {
        apps.apps.filter { (!userOnly || $0.isUserApp) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.bundleID.localizedCaseInsensitiveContains(query)) }
    }

    private var appsList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Search apps", text: $query).textFieldStyle(.roundedBorder)
                Toggle("User apps", isOn: $userOnly).toggleStyle(.checkbox)
                Button { apps.load() } label: { Image(systemName: "arrow.clockwise") }.help("Reload")
                Button { apps.pickIPA() } label: { Label("Install IPA", systemImage: "plus.app") }
            }
            .padding(10)
            List(shown) { app in
                HStack(spacing: 10) {
                    Image(systemName: "app.fill").font(.title2).foregroundStyle(Theme.gradient).frame(width: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name).font(.callout.weight(.semibold)).lineLimit(1)
                        Text("\(app.bundleID)  \(app.version)").font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { apps.launch(app) }
                .contextMenu {
                    Button("Launch") { apps.launch(app) }
                    if app.isUserApp { Button("Uninstall…", role: .destructive) { apps.uninstall(app) } }
                }
            }
            .listStyle(.plain)
            HStack(spacing: 8) {
                if apps.loading { ProgressView().controlSize(.small) }
                Text(apps.message ?? "\(shown.count) apps · double-click to launch · right-click for more").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
            }
            .padding(8)
        }
        .onAppear { if apps.apps.isEmpty { apps.load() } }
    }

    private var info: some View {
        Form {
            LabeledContent("Name", value: device.name)
            LabeledContent("Model", value: device.model)
            LabeledContent("iOS", value: device.osVersion)
            LabeledContent("Connection", value: device.transport == .usb ? "USB" : "Wi‑Fi")
            LabeledContent("UDID", value: device.udid)
            Text("iPhone support uses Apple's devicectl (Xcode 15+, iOS 17+). Mirroring is view-only and needs the cable; Apple does not allow remote touch or keyboard input.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
