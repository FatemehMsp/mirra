import SwiftUI

/// Broadcasts a trim request when macOS reports memory pressure (e.g. a Gradle build competing for RAM).
enum MemoryPressure {
    static let trim = Notification.Name("AndroidMonitor.TrimMemory")
    nonisolated(unsafe) private static var source: DispatchSourceMemoryPressure?

    static func start() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { NotificationCenter.default.post(name: trim, object: nil) }
        source.resume()
        self.source = source
    }
}

@main
struct AndroidMonitorApp: App {
    @StateObject private var updates = UpdateModel()

    init() { MemoryPressure.start() }

    var body: some Scene {
        WindowGroup(AppIdentity.name) {
            MainWindowView()
                .environmentObject(updates)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updates.checkForUpdates() }
                    .keyboardShortcut("u", modifiers: [.command])
            }
        }
    }
}
