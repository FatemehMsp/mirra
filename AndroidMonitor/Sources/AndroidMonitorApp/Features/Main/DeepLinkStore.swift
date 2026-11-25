import Foundation

/// Saved deep links per device, persisted as JSON in Application Support so they survive restarts.
/// Recent launches are kept per device too, for the history dropdown.
@MainActor
final class DeepLinkStore: ObservableObject {
    struct SavedLink: Identifiable, Codable, Equatable {
        let id: UUID
        var name: String
        var url: String
    }

    @Published private(set) var links: [SavedLink] = []
    @Published private(set) var recent: [String] = []

    private let serial: String
    private let storeURL: URL

    init(serial: String) {
        self.serial = serial
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mirra", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.storeURL = root.appendingPathComponent("deep-links-\(serial).json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let saved = try? JSONDecoder().decode([SavedLink].self, from: data) else { return }
        links = saved
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(links) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    func add(name: String, url: String) {
        guard !url.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        links.append(SavedLink(id: UUID(), name: name.isEmpty ? url : name, url: url))
        save()
    }

    func remove(id: UUID) {
        links.removeAll { $0.id == id }
        save()
    }

    func launch(_ url: String) {
        recent.removeAll { $0 == url }
        recent.insert(url, at: 0)
        if recent.count > 10 { recent.removeLast() }
        let adb = ADBClient(adbURL: AppADB.url)
        let service = AppActionsService(adb: adb, serial: serial)
        Task { try? await service.launch(deepLink: url) }
    }
}
