import Foundation

/// Keeps one `adb shell` session open and pipes input commands into it, avoiding a fresh adb process per event.
@MainActor
final class RemoteInput {
    private let serial: String
    private var process: Process?
    private var stdin: FileHandle?
    private var typed = ""
    private var typedTask: Task<Void, Never>?
    private let unicode: UnicodeTypingModel

    init(serial: String, unicode: UnicodeTypingModel) {
        self.serial = serial
        self.unicode = unicode
    }

    var unicodeTyping: UnicodeTypingModel { unicode }

    func stop() {
        typedTask?.cancel(); process?.terminate(); process = nil; stdin = nil
        unicode.restoreOnStop()
    }

    private func ensureShell() -> FileHandle? {
        if let process, process.isRunning, let stdin { return stdin }
        let pipe = Pipe()
        let p = Process()
        p.executableURL = AppADB.url
        p.arguments = ["-s", serial, "shell"]
        p.standardInput = pipe
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        process = p; stdin = pipe.fileHandleForWriting
        return stdin
    }

    func run(_ command: String) {
        guard let handle = ensureShell() else { return }
        try? handle.write(contentsOf: Data((command + "\n").utf8))
    }

    func tap(_ x: Int, _ y: Int) { run("input tap \(x) \(y)") }
    func swipe(_ x1: Int, _ y1: Int, _ x2: Int, _ y2: Int, durationMs: Int) { run("input swipe \(x1) \(y1) \(x2) \(y2) \(durationMs)") }
    func keyEvents(_ codes: [Int]) { flushTyped(); run("input keyevent " + codes.map(String.init).joined(separator: " ")) }

    /// Batches fast typing into a single `input text` call when Unicode typing is off;
    /// when on, text goes through the ADBKeyboard IME so Persian and emoji work.
    func type(_ text: String) {
        if unicode.enabled {
            unicode.type(text)
            return
        }
        typed += text
        typedTask?.cancel()
        typedTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(35))
            guard !Task.isCancelled else { return }
            self?.flushTyped()
        }
    }

    private func flushTyped() {
        typedTask?.cancel()
        let ascii = typed.filter { $0.isASCII && !$0.isNewline }
        typed = ""
        guard !ascii.isEmpty else { return }
        let escaped = ascii.replacingOccurrences(of: " ", with: "%s")
        run("input text '" + escaped.replacingOccurrences(of: "'", with: "'\"'\"'") + "'")
    }

    /// Pastes the Mac clipboard by typing it; newlines become Enter presses.
    func paste(_ text: String) {
        flushTyped()
        if unicode.enabled {
            // The IME handles the whole UTF-8 string, including newlines.
            unicode.type(text)
            return
        }
        if text.contains(where: { !$0.isASCII && !$0.isNewline }) {
            // Fall back to enabling Unicode typing on demand for this paste.
            if !unicode.busy { unicode.toggle() }
            Task {
                // Wait for the toggle to finish, then type through the IME.
                while unicode.busy { try? await Task.sleep(for: .milliseconds(150)) }
                if unicode.enabled { unicode.type(text) }
            }
            return
        }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            if !line.isEmpty { typed = line; flushTyped() }
            if index < lines.count - 1 { run("input keyevent 66") }
        }
    }
}
