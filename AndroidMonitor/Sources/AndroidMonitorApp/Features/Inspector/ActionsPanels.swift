import AppKit
import SwiftUI

/// One-click QA actions on the device: clear app data, grant permissions, flip dark mode,
/// and enable Unicode typing through the ADBKeyboard IME.
struct ActionsPanel: View {
    let serial: String
    @State private var package = ""
    @State private var status = ""
    @State private var busy = false

    private var service: AppActionsService {
        AppActionsService(adb: ADBClient(adbURL: AppADB.url), serial: serial)
    }

    var body: some View {
        Form {
            Section("App") {
                TextField("Package ID (e.g. com.example.app)", text: $package)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    Button("Clear Data") { run { try await service.clearData(package: package) } }
                        .disabled(package.isEmpty || busy)
                    Button("Grant All Permissions") { run { try await service.grantAllPermissions(package: package) } }
                        .disabled(package.isEmpty || busy)
                }
            }
            Section("Device") {
                HStack(spacing: 8) {
                    Button("Dark Mode") { run { try await service.setDarkMode(true) } }.disabled(busy)
                    Button("Light Mode") { run { try await service.setDarkMode(false) } }.disabled(busy)
                }
            }
            Section("Typing") {
                Text("Enable Unicode typing (Persian, emoji) through the ADBKeyboard IME. The device will use the Mirra keyboard while enabled.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Enable Unicode Typing") { enableUnicodeTyping() }.disabled(busy)
            }
            if !status.isEmpty {
                Section { Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
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

    private func enableUnicodeTyping() {
        busy = true
        status = ""
        let serial = serial
        Task {
            let adb = ADBClient(adbURL: AppADB.url)
            let keyboard = ADBKeyboard(adb: adb, serial: serial)
            if !(await keyboard.isInstalled()) {
                status = "Installing ADBKeyboard…"
                let destination = FileManager.default.temporaryDirectory.appendingPathComponent("ADBKeyboard.apk")
                do {
                    let (data, _) = try await URLSession.shared.data(from: ADBKeyboard.apkURL)
                    try data.write(to: destination)
                    _ = try await adb.run(serial: serial, arguments: ["install", destination.path], timeout: .seconds(60))
                } catch {
                    status = "Install failed: \(error.localizedDescription)"
                    busy = false
                    return
                }
            }
            let activated = await keyboard.activate()
            status = activated
                ? "Unicode typing is on. Use ⌘V in the mirror to paste text into the focused field."
                : "Could not switch the keyboard automatically — enable ADBKeyboard in Settings → System → Languages → On-screen keyboard, then tap Enable again."
            busy = false
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
