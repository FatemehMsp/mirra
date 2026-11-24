import Foundation

/// Detects Android crashes and ANRs in logcat lines and collects their stack traces.
public struct CrashEvent: Sendable, Equatable {
    public enum Kind: String, Sendable { case fatal, anr }
    public let kind: Kind
    public let timestamp: Date
    public let summary: String
    public let trace: String

    public init(kind: Kind, timestamp: Date, summary: String, trace: String) {
        self.kind = kind
        self.timestamp = timestamp
        self.summary = summary
        self.trace = trace
    }
}

/// Line-fed, stateful detector. `FATAL EXCEPTION` starts a crash block; `ANR in <package>` starts
/// an ANR block; the block ends when a line no longer looks like part of the trace.
public final class CrashWatcher {
    public enum State { case idle, collecting(CrashEvent.Kind, Date, String, [String]) }

    private var state: State = .idle

    public init() {}

    /// Feeds one logcat line (already decoded, without the trailing newline). Returns a finished
    /// event when the collected block completes.
    public func feed(line: String, timestamp: Date = .now) -> CrashEvent? {
        switch state {
        case .idle:
            if line.contains("FATAL EXCEPTION") {
                state = .collecting(.fatal, timestamp, line, [])
            } else if let package = Self.anrPackage(in: line) {
                state = .collecting(.anr, timestamp, "ANR in \(package)", [])
            }
            return nil
        case .collecting(let kind, let started, let summary, var lines):
            if Self.isTraceLine(line) {
                lines.append(line)
                state = .collecting(kind, started, summary, lines)
                return nil
            }
            state = .idle
            // The summary alone is enough if nothing was collected.
            let trace = ([summary] + lines).joined(separator: "\n")
            // A terminating line can itself be the start of the next event; the collector
            // will pick it up on its next feed call.
            return CrashEvent(kind: kind, timestamp: started, summary: summary, trace: trace)
        }
    }

    /// `"ANR in com.example.app"` → `com.example.app`
    public static func anrPackage(in line: String) -> String? {
        guard let range = line.range(of: "ANR in ") else { return nil }
        let tail = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return tail.isEmpty ? nil : tail.split(separator: " ").first.map(String.init)
    }

    /// Stack-trace-shaped lines: the exception header, `at …`, `Caused by:`, `… N more`,
    /// or the `Dalvik`/`Runtime` banner lines a crash dumps. Logcat prefixes every line with
    /// `E AndroidRuntime:`, so the payload is what matters after that marker.
    public static func isTraceLine(_ line: String) -> Bool {
        let payload = line.components(separatedBy: "AndroidRuntime:").last ?? line
        let trimmed = payload.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return false }
        if trimmed.hasPrefix("at ") || trimmed.hasPrefix("Caused by:") || trimmed.hasPrefix("... ") { return true }
        if trimmed.hasPrefix("Exception") || trimmed.hasPrefix("Suppressed:") { return true }
        if trimmed.contains("Exception") || trimmed.contains("Error") { return true }
        if trimmed.hasPrefix("Process:") || trimmed.hasPrefix("PID:") || trimmed.hasPrefix("UID:") { return true }
        return false
    }
}
