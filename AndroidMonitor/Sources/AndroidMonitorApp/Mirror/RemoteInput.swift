import Foundation

/// Keeps one `adb shell` session open and pipes input commands into it, avoiding a fresh adb process per event.
@MainActor
final class RemoteInput {
    private let serial: String
    private var process: Process?
    private var stdin: FileHandle?
    private var typed = ""
    private var typedTask: Task<Void, Never>?

    init(serial: String) { self.serial = serial }

    private var previousIME: String?
    private var unicodeIMEActive = false

    func stop() {
        typedTask?.cancel(); process?.terminate(); process = nil; stdin = nil
        // Leave the device with its own keyboard when the mirror goes away.
        restoreIME()
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

    /// Batches fast typing into a single `input text` call. `input text` only handles ASCII, so other characters are dropped.
    func type(_ text: String) {
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
        // Any non-ASCII text needs the ADBKeyboard IME; ASCII keeps the fast path.
        if text.contains(where: { !$0.isASCII && !$0.isNewline }) {
            pasteUnicode(text)
            return
        }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            if !line.isEmpty { typed = line; flushTyped() }
            if index < lines.count - 1 { run("input keyevent 66") }
        }
    }

    /// Switches to the ADBKeyboard IME on first use (installing it if needed), types the text,
    /// then switches back to the user's own keyboard.
    private func pasteUnicode(_ text: String) {
        let serial = serial
        Task {
            let adb = ADBClient(adbURL: AppADB.url)
            let keyboard = ADBKeyboard(adb: adb, serial: serial)
            if !(await keyboard.isInstalled()) {
                let destination = FileManager.default.temporaryDirectory.appendingPathComponent("ADBKeyboard.apk")
                guard let (data, _) = try? await URLSession.shared.data(from: ADBKeyboard.apkURL),
                      let _ = try? data.write(to: destination) else { return }
                _ = try? await adb.run(serial: serial, arguments: ["install", destination.path], timeout: .seconds(60))
            }
            if previousIME == nil { previousIME = await keyboard.currentIME() }
            if await keyboard.activate() {
                unicodeIMEActive = true
                try? await keyboard.type(text: text)
                await keyboard.switchBack()
                restoreIME()
            }
        }
    }

    private func restoreIME() {
        guard unicodeIMEActive, let previous = previousIME, !previous.isEmpty else { return }
        unicodeIMEActive = false
        previousIME = nil
        let adb = ADBClient(adbURL: AppADB.url)
        let serial = serial
        Task { _ = try? await adb.run(serial: serial, arguments: ["shell", "ime", "set", previous], timeout: .seconds(10)) }
    }
}
