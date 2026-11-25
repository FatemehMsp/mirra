import AppKit
import SwiftUI

private let adbURL = AppADB.url

struct InspectorPanels: View {
    let serial: String
    @State private var tab = Tab.files
    @StateObject private var links: DeepLinkStore
    @ObservedObject var unicode: UnicodeTypingModel
    @ObservedObject var crashRecorder: CrashRecorder

    init(serial: String, unicode: UnicodeTypingModel, crashRecorder: CrashRecorder) {
        self.serial = serial
        self.unicode = unicode
        self.crashRecorder = crashRecorder
        _links = StateObject(wrappedValue: DeepLinkStore(serial: serial))
    }

    enum Tab: String, CaseIterable {
        case files = "Files", apps = "Apps", data = "Data", logcat = "Logcat", actions = "Actions", links = "Links", tools = "Tools", shell = "Shell", info = "Info"
        var icon: String {
            switch self {
            case .files: return "folder.fill"
            case .apps: return "square.grid.2x2.fill"
            case .data: return "externaldrive.fill"
            case .logcat: return "text.alignleft"
            case .actions: return "bolt.fill"
            case .links: return "link"
            case .tools: return "wrench.and.screwdriver.fill"
            case .shell: return "terminal.fill"
            case .info: return "info.circle.fill"
            }
        }
        var color: Color {
            switch self {
            case .files: return .yellow
            case .apps: return Theme.accent
            case .data: return .purple
            case .logcat: return .orange
            case .actions: return .red
            case .links: return .blue
            case .tools: return .indigo
            case .shell: return .pink
            case .info: return Theme.accent2
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // A wrapping flow layout keeps every tab visible on one or two rows; nine tabs do
            // not fit a narrow panel, and hidden (scrolled-off) tabs looked broken.
            TabFlowLayout(spacing: 4) {
                ForEach(Tab.allCases, id: \.self) { item in
                    Button { tab = item } label: {
                        Label(item.rawValue, systemImage: item.icon)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .foregroundStyle(tab == item ? Color.white : Color.secondary)
                            .background(Capsule().fill(tab == item ? item.color.opacity(0.75) : Color.clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(.bar)
            Divider()
            ZStack {
                page(.files) { FilesPanel(serial: serial) }
                page(.apps) { AppsPanel(serial: serial) }
                page(.data) { DataPanel(serial: serial) }
                page(.logcat) { LogcatPanel(serial: serial, active: tab == .logcat) }
                page(.actions) { ActionsPanel(serial: serial, unicode: unicode, crashRecorder: crashRecorder) }
                page(.links) { DeepLinksPanel(store: links) }
                page(.tools) { ToolsPanel(serial: serial) }
                page(.shell) { ShellPanel(serial: serial) }
                page(.info) { InfoPanel(serial: serial) }
            }
        }
        .frame(minWidth: 340)
    }

    private func page<Content: View>(_ item: Tab, @ViewBuilder _ content: () -> Content) -> some View {
        content().opacity(tab == item ? 1 : 0).allowsHitTesting(tab == item)
    }
}

private struct DataPanel: NSViewRepresentable {
    let serial: String
    func makeCoordinator() -> Coordinator { Coordinator(serial: serial) }
    func makeNSView(context: Context) -> TextPanelView { context.coordinator.makeView() }
    func updateNSView(_ nsView: TextPanelView, context: Context) {}
    @MainActor final class Coordinator: NSObject {
        let serial: String; let mode = NSPopUpButton(); let package = NSTextField(); let path = NSTextField(); weak var view: TextPanelView?
        init(serial: String) { self.serial = serial }
        func makeView() -> TextPanelView {
            let v = TextPanelView(); view = v
            mode.addItems(withTitles: ["Normal", "Debuggable", "Root"]); package.placeholderString = "Package ID"; path.stringValue = "/data/data"
            v.controls.addArrangedSubview(mode); v.controls.addArrangedSubview(package); v.controls.addArrangedSubview(path)
            for (title, action) in [("List", #selector(list)), ("Read", #selector(read)), ("Replace", #selector(replace))] { v.controls.addArrangedSubview(NSButton(title: title, target: self, action: action)) }
            return v
        }
        var access: AccessLevel {
            switch mode.indexOfSelectedItem { case 1: return .debuggable(package: package.stringValue); case 2: return .root; default: return .normal }
        }
        @objc func list() { Task { do { let files = try await ProtectedDataService(adbURL: adbURL, serial: serial).list(path: path.stringValue, access: access); view?.show(files.map(\.path).joined(separator: "\n")) } catch { view?.show("Error: \(error.localizedDescription)") } } }
        @objc func read() {
            let save = NSSavePanel(); save.nameFieldStringValue = URL(fileURLWithPath: path.stringValue).lastPathComponent
            guard save.runModal() == .OK, let url = save.url else { return }
            Task { do { let data = try await ProtectedDataService(adbURL: adbURL, serial: serial).read(path: path.stringValue, access: access); try data.write(to: url, options: .atomic); view?.append("\nSaved → \(url.path)") } catch { view?.append("\nError: \(error.localizedDescription)") } }
        }
        @objc func replace() {
            let open = NSOpenPanel(); guard open.runModal() == .OK, let url = open.url, let data = try? Data(contentsOf: url) else { return }
            let alert = NSAlert(); alert.messageText = "Replace protected file?"; alert.informativeText = "Device: \(serial)\nTarget: \(path.stringValue)\nAccess: \(mode.titleOfSelectedItem ?? "")"; alert.addButton(withTitle: "Replace"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            Task { do { try await ProtectedDataService(adbURL: adbURL, serial: serial).write(data, path: path.stringValue, access: access); view?.append("\nReplaced") } catch { view?.append("\nError: \(error.localizedDescription)") } }
        }
    }
}

private final class TextPanelView: NSView {
    let controls = NSStackView()
    let text = NSTextView()
    override init(frame: NSRect) {
        super.init(frame: frame)
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        controls.orientation = .horizontal
        controls.spacing = 6
        let stack = NSStackView(views: [controls, scroll])
        stack.orientation = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            controls.heightAnchor.constraint(equalToConstant: 28)
        ])
    }
    required init?(coder: NSCoder) { nil }
    func show(_ value: String) { text.string = value }
    func append(_ value: String) {
        text.textStorage?.append(NSAttributedString(string: value))
        if text.string.count > 2_000_000 { text.string = String(text.string.suffix(1_000_000)) }
        text.scrollToEndOfDocument(nil)
    }
}

private struct FilePanel: NSViewRepresentable {
    let serial: String
    func makeCoordinator() -> Coordinator { Coordinator(serial: serial) }
    func makeNSView(context: Context) -> TextPanelView { context.coordinator.makeView() }
    func updateNSView(_ nsView: TextPanelView, context: Context) {}

    @MainActor final class Coordinator: NSObject {
        let serial: String
        let path = NSTextField(string: "/sdcard")
        weak var view: TextPanelView?
        init(serial: String) { self.serial = serial }
        func makeView() -> TextPanelView {
            let view = TextPanelView(); self.view = view
            path.placeholderString = "Remote path"
            path.setContentHuggingPriority(.defaultLow, for: .horizontal)
            view.controls.addArrangedSubview(path)
            for (title, action) in [("Reload", #selector(reload)), ("Pull", #selector(pull)), ("Push", #selector(push)), ("Delete", #selector(remove))] {
                let button = NSButton(title: title, target: self, action: action); view.controls.addArrangedSubview(button)
            }
            reload(); return view
        }
        @objc func reload() {
            let target = path.stringValue
            Task {
                do {
                    let files = try await FileService(adb: ADBClient(adbURL: adbURL), serial: serial).list(target)
                    view?.show(files.map { "\($0.name)\t\($0.path)" }.joined(separator: "\n"))
                } catch { view?.show("Error: \(error.localizedDescription)") }
            }
        }
        @objc func pull() {
            let panel = NSSavePanel(); panel.nameFieldStringValue = URL(fileURLWithPath: path.stringValue).lastPathComponent
            guard panel.runModal() == .OK, let url = panel.url else { return }
            Task { do { try await FileService(adb: ADBClient(adbURL: adbURL), serial: serial).pull(remote: path.stringValue, local: url); view?.append("\nDownloaded → \(url.path)") } catch { view?.append("\nError: \(error.localizedDescription)") } }
        }
        @objc func push() {
            let panel = NSOpenPanel(); guard panel.runModal() == .OK, let url = panel.url else { return }
            let remote = path.stringValue.hasSuffix("/") ? path.stringValue + url.lastPathComponent : path.stringValue
            Task { do { try await FileService(adb: ADBClient(adbURL: adbURL), serial: serial).push(local: url, remote: remote); reload() } catch { view?.append("\nError: \(error.localizedDescription)") } }
        }
        @objc func remove() {
            let alert = NSAlert(); alert.messageText = "Delete remote path?"; alert.informativeText = path.stringValue; alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            Task { do { try await FileService(adb: ADBClient(adbURL: adbURL), serial: serial).remove(path.stringValue); reload() } catch { view?.append("\nError: \(error.localizedDescription)") } }
        }
    }
}

private struct LogcatPanel: NSViewRepresentable {
    let serial: String
    let active: Bool
    func makeNSView(context: Context) -> LogcatView { LogcatView(serial: serial) }
    func updateNSView(_ nsView: LogcatView, context: Context) { nsView.setActive(active) }
}

private struct ShellPanel: NSViewRepresentable {
    let serial: String
    func makeCoordinator() -> Coordinator { Coordinator(serial: serial) }
    func makeNSView(context: Context) -> TextPanelView { context.coordinator.makeView() }
    func updateNSView(_ nsView: TextPanelView, context: Context) {}
    @MainActor final class Coordinator: NSObject {
        let serial: String; let command = NSTextField(); weak var view: TextPanelView?
        init(serial: String) { self.serial = serial }
        func makeView() -> TextPanelView { let v = TextPanelView(); view = v; command.placeholderString = "Command"; v.controls.addArrangedSubview(command); v.controls.addArrangedSubview(NSButton(title: "Run", target: self, action: #selector(run))); return v }
        @objc func run() { let value = command.stringValue; view?.append("$ \(value)\n"); Task { do { let output = try await ShellService(adb: ADBClient(adbURL: adbURL), serial: serial).execute(value); view?.append(output + "\n") } catch { view?.append("Error: \(error.localizedDescription)\n") } } }
    }
}

private struct InfoPanel: NSViewRepresentable {
    let serial: String
    func makeNSView(context: Context) -> TextPanelView {
        let v = TextPanelView(); v.controls.addArrangedSubview(NSTextField(labelWithString: serial))
        Task { do { let i = try await DeviceInfoService(adb: ADBClient(adbURL: adbURL), serial: serial).load(); await MainActor.run { v.show("Manufacturer: \(i.manufacturer ?? "—")\nModel: \(i.model ?? "—")\nAndroid: \(i.androidVersion ?? "—")\nAPI: \(i.apiLevel ?? "—")\nABI: \(i.abi ?? "—")") } } catch { await MainActor.run { v.show("Error: \(error.localizedDescription)") } } }
        return v
    }
    func updateNSView(_ nsView: TextPanelView, context: Context) {}
}

