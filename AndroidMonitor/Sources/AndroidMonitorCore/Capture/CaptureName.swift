import Foundation

/// File names for captured media: a fixed prefix plus a timestamp, so repeated captures
/// never overwrite each other and sort naturally by name.
public enum CaptureName {
    /// `file(prefix: "screenshot", fileExtension: "png", date: …)` → `screenshot-20261112-153004.png`
    public static func file(prefix: String, fileExtension: String, date: Date, timeZone: TimeZone = .current) -> String {
        "\(prefix)-\(stamp(date: date, timeZone: timeZone)).\(fileExtension)"
    }

    public static func stamp(date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
