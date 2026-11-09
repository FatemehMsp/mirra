import Foundation

/// Android Studio style logcat query, e.g. `package:com.example tag:OkHttp level:warn -tag:Choreographer is:crash timeout`.
///
/// Terms (space separated, all must match):
/// - `package:<text>` / `tag:<text>` / `message:<text>` / `pid:<n>`: case-insensitive contains (pid is exact)
/// - `level:<v|d|i|w|e|f or name>`: minimum priority
/// - `is:crash`: fatal entries and `AndroidRuntime` errors
/// - `tag=:<text>`, `package=:<text>`: exact match
/// - `tag~:<regex>`, `package~:<regex>`, `message~:<regex>`: regular expression
/// - a leading `-` negates a term; free words search the tag and the message
/// - several terms with the same key are OR-ed (like Android Studio), different keys are AND-ed
public struct LogcatFilter: Sendable {
    public struct Term: Sendable, Equatable {
        public enum Key: String, Sendable { case package, tag, message, pid, level, isCrash, text }
        public enum Mode: Sendable, Equatable { case contains, exact, regex }
        public let key: Key
        public let value: String
        public let mode: Mode
        public let negated: Bool
    }

    public let terms: [Term]
    public var minimumLevel: LogPriority? {
        terms.first { $0.key == .level && !$0.negated }.flatMap { LogPriority.parse($0.value) }
    }
    /// Plain words, used for highlighting matches in the output.
    public var highlightWords: [String] { terms.filter { ($0.key == .text || $0.key == .message) && !$0.negated && $0.mode == .contains }.map(\.value) }

    public init(_ query: String) {
        terms = query.split(whereSeparator: \.isWhitespace).compactMap { Self.term(String($0)) }
    }

    private static func term(_ raw: String) -> Term? {
        var token = raw
        var negated = false
        if token.hasPrefix("-"), token.count > 1 { negated = true; token.removeFirst() }
        guard let colon = token.firstIndex(of: ":") else {
            return Term(key: .text, value: token, mode: .contains, negated: negated)
        }
        var keyName = String(token[..<colon])
        let value = String(token[token.index(after: colon)...])
        var mode = Term.Mode.contains
        if keyName.hasSuffix("~") { mode = .regex; keyName.removeLast() } else if keyName.hasSuffix("=") { mode = .exact; keyName.removeLast() }
        let key: Term.Key
        switch keyName.lowercased() {
        case "package", "pkg", "app": key = .package
        case "tag": key = .tag
        case "message", "msg": key = .message
        case "pid": key = .pid
        case "level": key = .level
        case "is" where value.lowercased() == "crash": key = .isCrash
        default: return Term(key: .text, value: raw, mode: .contains, negated: false)
        }
        guard !value.isEmpty || key == .isCrash else { return nil }
        return Term(key: key, value: value, mode: mode, negated: negated)
    }

    /// `packageName` is the process name of the entry's pid (nil when unknown).
    public func matches(_ entry: LogcatEntry, packageName: String?) -> Bool {
        let grouped = Dictionary(grouping: terms.filter { !$0.negated }, by: \.key)
        for (_, group) in grouped where !group.contains(where: { Self.check($0, entry, packageName) }) { return false }
        for term in terms where term.negated && Self.check(term, entry, packageName) { return false }
        return true
    }

    private static func check(_ term: Term, _ entry: LogcatEntry, _ package: String?) -> Bool {
        switch term.key {
        case .package: return compare(package ?? "", term)
        case .tag: return compare(entry.tag, term)
        case .message: return compare(entry.message, term)
        case .text: return compare(entry.tag, term) || compare(entry.message, term)
        case .pid: return Int(term.value) == entry.pid
        case .level: return (LogPriority.parse(term.value).map { entry.priority.rank >= $0.rank }) ?? true
        case .isCrash: return entry.priority == .fatal || (entry.priority == .error && entry.tag == "AndroidRuntime")
        }
    }

    private static func compare(_ field: String, _ term: Term) -> Bool {
        switch term.mode {
        case .contains: return field.localizedCaseInsensitiveContains(term.value)
        case .exact: return field.caseInsensitiveCompare(term.value) == .orderedSame
        case .regex: return (try? NSRegularExpression(pattern: term.value, options: .caseInsensitive))?
            .firstMatch(in: field, range: NSRange(field.startIndex..., in: field)) != nil
        }
    }
}

public extension LogPriority {
    var rank: Int { [.verbose, .debug, .info, .warning, .error, .fatal].firstIndex(of: self) ?? 0 }

    static func parse(_ text: String) -> LogPriority? {
        switch text.lowercased() {
        case "v", "verbose": return .verbose
        case "d", "debug": return .debug
        case "i", "info": return .info
        case "w", "warn", "warning": return .warning
        case "e", "error": return .error
        case "f", "fatal", "a", "assert": return .fatal
        default: return nil
        }
    }
}

/// Parses `ps -A -o PID,NAME` from the device into pid → process (package) name.
public enum ProcessTableParser {
    public static func parse(_ output: String) -> [Int: String] {
        var table: [Int: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int(parts[0]) else { continue }
            table[pid] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        return table
    }
}
