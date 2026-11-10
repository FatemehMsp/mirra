import AppKit

/// Android-Studio-style logcat: package column, colored levels, a query language (see `LogcatFilter`), app and level pickers.
@MainActor
final class LogcatView: NSView, NSSearchFieldDelegate, NSTextFieldDelegate {
    private let serial: String
    private let search = NSSearchField()
    private let appPicker = NSPopUpButton()
    private let level = NSPopUpButton()
    private var filter = LogcatFilter("")
    private var pidNames: [Int: String] = [:]
    private var psTask: Task<Void, Never>?
    private let pauseButton = NSButton(checkboxWithTitle: "Pause", target: nil, action: nil)
    private let text = NSTextView()
    private let counter = NSTextField(labelWithString: "")

    private var entries: [LogcatEntry] = []
    private var pending: [LogcatEntry] = []
    private var partial = ""
    private var task: Task<Void, Never>?
    private var flushTimer: Timer?
    private let maxEntries = 2_000
    private let maxVisible = 800
    private let maxTextLength = 150_000
    private var isActive = false
    private static let levels: [LogPriority] = [.verbose, .debug, .info, .warning, .error, .fatal]

    init(serial: String) {
        self.serial = serial
        super.init(frame: .zero)
        build()
    }
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() { if window == nil { stop() } }

    // MARK: UI
    private var pressureObserver: NSObjectProtocol?

    private func build() {
        pressureObserver = NotificationCenter.default.addObserver(forName: MemoryPressure.trim, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.trimMemory() }
        }
        search.placeholderString = "package:com.app tag:OkHttp level:warn -tag:Choreographer is:crash"
        search.delegate = self
        search.toolTip = Self.syntaxHelp
        appPicker.addItem(withTitle: "All apps")
        appPicker.target = self; appPicker.action = #selector(filtersChanged)
        appPicker.widthAnchor.constraint(lessThanOrEqualToConstant: 190).isActive = true
        level.addItems(withTitles: ["Verbose", "Debug", "Info", "Warn", "Error", "Fatal"])
        level.target = self; level.action = #selector(filtersChanged)
        pauseButton.target = self; pauseButton.action = #selector(togglePause)
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearAll))
        let save = NSButton(title: "Save", target: self, action: #selector(saveLog))
        counter.font = .systemFont(ofSize: 10); counter.textColor = .secondaryLabelColor

        let help = NSButton(title: "", target: self, action: #selector(showHelp))
        help.bezelStyle = .helpButton
        let bar = NSStackView(views: [search, help, appPicker, level, pauseButton, clear, save])
        bar.spacing = 6
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        text.isEditable = false
        text.isRichText = true
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.backgroundColor = NSColor.textBackgroundColor
        text.autoresizingMask = [.width]
        text.isHorizontallyResizable = false
        text.textContainer?.widthTracksTextView = true

        let stack = NSStackView(views: [bar, scroll, counter])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    // MARK: Streaming
    /// The adb logcat stream only runs while the Logcat tab is visible; hidden, it costs nothing.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active { start() } else { stop() }
    }

    func trimMemory() {
        entries.removeAll(keepingCapacity: false); pending.removeAll(keepingCapacity: false)
        text.textStorage?.setAttributedString(NSAttributedString()); updateCounter()
    }

    private func stop() {
        task?.cancel(); task = nil
        psTask?.cancel(); psTask = nil
        flushTimer?.invalidate(); flushTimer = nil
    }

    private func start() {
        stop()
        let serial = serial
        task = Task { [weak self] in
            do {
                for try await data in LogcatService(adb: ADBClient(adbURL: AppADB.url), serial: serial).stream() {
                    self?.ingest(String(decoding: data, as: UTF8.self))
                }
            } catch { self?.pending.append(LogcatEntry(timestamp: Date().timeIntervalSince1970, pid: 0, tid: 0, priority: .error, tag: "logcat", message: error.localizedDescription)) }
        }
        psTask = Task { [weak self] in
            let adb = ADBClient(adbURL: AppADB.url)
            while !Task.isCancelled {
                if let out = try? await adb.run(serial: serial, arguments: ["shell", "ps", "-A", "-o", "PID,NAME"], timeout: .seconds(10)).stdout {
                    self?.updateProcesses(ProcessTableParser.parse(String(decoding: out, as: UTF8.self)))
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
        flushTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    private func ingest(_ chunk: String) {
        partial += chunk
        var lines = partial.components(separatedBy: "\n")
        partial = lines.removeLast()
        for line in lines {
            if let entry = LogcatParser.entry(line.trimmingCharacters(in: .whitespacesAndNewlines)) { pending.append(entry) }
        }
    }

    private func flush() {
        guard !pending.isEmpty, !pauseButton.state.isOn else { return }
        let batch = pending; pending.removeAll()
        entries.append(contentsOf: batch)
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
        let visible = batch.filter(matches)
        guard !visible.isEmpty else { updateCounter(); return }
        let stick = isAtBottom
        text.textStorage?.append(render(visible))
        if let storage = text.textStorage, storage.length > maxTextLength {
            let cut = (storage.string as NSString).range(of: "\n", range: NSRange(location: storage.length - maxTextLength / 2, length: maxTextLength / 2)).upperBound
            storage.deleteCharacters(in: NSRange(location: 0, length: cut))
        }
        if stick { text.scrollToEndOfDocument(nil) }
        updateCounter()
    }

    private var isAtBottom: Bool {
        guard let scroll = text.enclosingScrollView else { return true }
        let visible = scroll.contentView.bounds
        return visible.maxY >= text.frame.height - 24
    }

    // MARK: Filtering & rendering
    private func rank(_ p: LogPriority) -> Int { p.rank }
    private func packageName(_ e: LogcatEntry) -> String? { pidNames[e.pid] }

    /// Process names are learned from `ps` every few seconds and kept after the process exits,
    /// so old lines keep their package. Known apps fill the app picker.
    private func updateProcesses(_ table: [Int: String]) {
        let before = pidNames.count
        pidNames.merge(table) { _, new in new }
        let apps = Set(table.values.filter { $0.contains(".") && !$0.hasPrefix("/") }.map { $0.split(separator: ":").first.map(String.init) ?? $0 })
        let current = Set(appPicker.itemTitles.dropFirst())
        if !apps.isSubset(of: current) {
            let selected = appPicker.titleOfSelectedItem
            appPicker.removeAllItems(); appPicker.addItem(withTitle: "All apps")
            appPicker.addItems(withTitles: current.union(apps).sorted())
            if let selected { appPicker.selectItem(withTitle: selected) }
        }
        // Lines that arrived before their pid was known now get a package; refresh if the view depends on it.
        if before == 0 || appPicker.indexOfSelectedItem > 0 || filter.terms.contains(where: { $0.key == .package }) { rebuild() }
    }

    private func matches(_ e: LogcatEntry) -> Bool {
        guard e.priority.rank >= level.indexOfSelectedItem else { return false }
        let package = packageName(e)
        if appPicker.indexOfSelectedItem > 0, let app = appPicker.titleOfSelectedItem,
           !(package == app || (package?.hasPrefix(app + ":") ?? false)) { return false }
        return filter.matches(e, packageName: package)
    }

    private static func color(_ p: LogPriority) -> NSColor {
        switch p {
        case .verbose: return .systemGray
        case .debug: return .systemBlue
        case .info: return NSColor(name: nil) { $0.bestMatch(from: [.darkAqua]) != nil ? NSColor(red: 0.45, green: 0.85, blue: 0.45, alpha: 1) : NSColor(red: 0.1, green: 0.5, blue: 0.1, alpha: 1) }
        case .warning: return .systemOrange
        case .error: return .systemRed
        case .fatal: return .systemPink
        }
    }

    private static let timeFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()

    private static func column(_ text: String, _ width: Int) -> String {
        text.count > width ? "…" + text.suffix(width - 1) : text.padding(toLength: width, withPad: " ", startingAt: 0)
    }

    private func render(_ list: [LogcatEntry]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        let words = filter.highlightWords
        for e in list {
            let c = Self.color(e.priority)
            let time = Self.timeFormat.string(from: Date(timeIntervalSince1970: e.timestamp))
            out.append(NSAttributedString(string: "\(time) \(Self.column("\(e.pid)-\(e.tid)", 11)) ", attributes: [.font: mono, .foregroundColor: NSColor.tertiaryLabelColor]))
            out.append(NSAttributedString(string: Self.column(packageName(e) ?? "pid-\(e.pid)", 26) + " ", attributes: [.font: mono, .foregroundColor: NSColor.secondaryLabelColor]))
            out.append(NSAttributedString(string: " \(e.priority.rawValue) ", attributes: [.font: bold, .foregroundColor: NSColor.black, .backgroundColor: c]))
            out.append(NSAttributedString(string: " " + Self.column(e.tag, 22) + " ", attributes: [.font: bold, .foregroundColor: c]))
            let message = NSMutableAttributedString(string: e.message + "\n", attributes: [.font: e.priority == .fatal || e.priority == .error ? bold : mono, .foregroundColor: c])
            for word in words {
                var range = message.string.startIndex..<message.string.endIndex
                while let found = message.string.range(of: word, options: .caseInsensitive, range: range) {
                    message.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.55), range: NSRange(found, in: message.string))
                    range = found.upperBound..<message.string.endIndex
                }
            }
            out.append(message)
        }
        return out
    }

    private func rebuild() {
        let shown = Array(entries.filter(matches).suffix(maxVisible))
        text.textStorage?.setAttributedString(render(shown))
        text.scrollToEndOfDocument(nil)
        updateCounter()
    }

    private func updateCounter() { counter.stringValue = "\(entries.count) lines buffered" }

    // MARK: Actions
    @objc private func filtersChanged() { rebuild() }
    func controlTextDidChange(_ obj: Notification) {
        filter = LogcatFilter(search.stringValue)
        if let min = filter.minimumLevel { level.selectItem(at: min.rank) }
        rebuild()
    }

    private static let syntaxHelp = """
    package:com.app      lines from that app (also pkg: / app:)
    tag:OkHttp           tag contains OkHttp      tag=:OkHttp exact     tag~:^Ok.* regex
    message:timeout      message contains timeout (or just type the word)
    level:warn           warn and above (v d i w e f)
    pid:4182             one process
    is:crash             crashes (fatal / AndroidRuntime)
    -tag:Choreographer   exclude
    Same key twice = OR (tag:A tag:B), different keys = AND.
    """

    @objc private func showHelp() {
        let alert = NSAlert()
        alert.messageText = "Logcat filter syntax"
        alert.informativeText = Self.syntaxHelp
        alert.runModal()
    }
    @objc private func togglePause() { if !pauseButton.state.isOn { flush() } }
    @objc private func clearAll() {
        entries.removeAll(); pending.removeAll(); text.string = ""; updateCounter()
        let serial = serial
        Task { try? await LogcatService(adb: ADBClient(adbURL: AppADB.url), serial: serial).clear() }
    }
    @objc private func saveLog() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "logcat.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.string.write(to: url, atomically: true, encoding: .utf8)
    }
}

private extension NSControl.StateValue { var isOn: Bool { self == .on } }
