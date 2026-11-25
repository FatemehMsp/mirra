import AppKit
import SwiftUI

/// One-click QA actions on the device: clear app data, grant permissions, flip dark mode,
/// and enable Unicode typing through the ADBKeyboard IME.
struct ActionsPanel: View {
    let serial: String
    @ObservedObject var unicode: UnicodeTypingModel
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
