import Foundation
import UserNotifications

/// Watches logcat for crashes and ANRs and raises a macOS notification with the stack trace.
/// Enabled by default so crashes never go unnoticed; the toggle lives in the Logcat panel.
@MainActor
final class CrashWatcherModel: ObservableObject {
    @Published var enabled = true
    @Published private(set) var lastEvent: CrashEvent?
    /// Set by the workspace so a crash can freeze the ring-buffer recorder.
    var onEvent: ((CrashEvent) -> Void)?

    private var task: Task<Void, Never>?
    private let serial: String

    init(serial: String) {
        self.serial = serial
    }

    func start() {
        guard task == nil else { return }
        let service = LogcatService(adb: ADBClient(adbURL: AppADB.url), serial: serial)
        task = Task { [weak self] in
            do {
                var buffer = ""
                for try await chunk in service.stream(recentLines: 100) {
                    guard !Task.isCancelled, let self, self.enabled else { continue }
                    buffer += String(decoding: chunk, as: UTF8.self)
                    let lines = buffer.components(separatedBy: .newlines)
                    buffer = lines.last ?? ""
                    for line in lines.dropLast() {
                        if let event = self.process(line: line) {
                            self.lastEvent = event
                            self.notify(event)
                            self.onEvent?(event)
                        }
                    }
                }
            } catch { }
        }
    }

    func stop() {
        task?.cancel(); task = nil
    }

    private func process(line: String) -> CrashEvent? {
        // Reuse one collector across lines so multi-line traces are kept together.
        collector.feed(line: line)
    }

    private let collector = CrashWatcher()

    /// Posts a macOS notification; permission is requested lazily on the first event.
    private func notify(_ event: CrashEvent) {
        let content = UNMutableNotificationContent()
        content.title = event.kind == .fatal ? "Crash on device" : "ANR on device"
        content.body = String(event.summary.prefix(180))
        content.sound = .default
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }

    /// The most recent trace, for the Copy button.
    var lastTrace: String? { lastEvent?.trace }
}
