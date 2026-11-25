import AppKit
import SwiftUI

/// Media and reporting utilities that run on captured artifacts: the packaged bug report,
/// lossless video trimming and GIF export.
struct ToolsPanel: View {
    let serial: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                BugReportSection(serial: serial)
                TrimSection()
                GifSection()
            }
            .padding(12)
        }
    }
}

// MARK: - Bug report

private struct BugReportSection: View {
    let serial: String
    @State private var package = ""
    @State private var status = ""
    @State private var busy = false

    var body: some View {
        GroupBox("Bug report") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Bundles a screenshot, the recent logcat, device properties, key dumpsys sections and — with a package — its full pm dump into one zip, ready to attach to a ticket.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("Package (optional)", text: $package)
                        .textFieldStyle(.roundedBorder)
                    Button("Create report") { create() }
                        .disabled(busy)
                    if busy { ProgressView().controlSize(.small) }
                }
                if !status.isEmpty {
                    Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
    }

    private func create() {
        busy = true
        status = "Collecting from the device…"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = CaptureName.file(prefix: "bugreport-\(serial)", fileExtension: "zip", date: .now)
        guard panel.runModal() == .OK, let url = panel.url else {
            busy = false
            status = ""
            return
        }
        let service = BugReportService(adb: ADBClient(adbURL: AppADB.url), serial: serial)
        let package = package
        Task {
            do {
                let report = try await service.create(destination: url, package: package.isEmpty ? nil : package)
                status = "Saved \(report.fileCount) files → \(url.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                status = "Error: \(error.localizedDescription)"
            }
            busy = false
        }
    }
}

// MARK: - Trim

private struct TrimSection: View {
    @State private var source: URL?
    @State private var duration: Double = 0
    @State private var start = 0.0
    @State private var end = 0.0
    @State private var status = ""
    @State private var busy = false

    var body: some View {
        GroupBox("Trim video") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button(source == nil ? "Choose video…" : source!.lastPathComponent) {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
                        panel.allowsMultipleSelection = false
                        guard panel.runModal() == .OK, let url = panel.url else { return }
                        load(url)
                    }
                    .lineLimit(1).truncationMode(.middle)
                    if source != nil {
                        Text(String(format: "%.1fs", duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if source != nil, duration > 0 {
                    HStack(spacing: 8) {
                        Text("Range").font(.caption)
                        Slider(value: $start, in: 0...max(duration - 0.2, 0.1))
                        Text(String(format: "%.1f", start)).font(.caption.monospacedDigit()).frame(width: 34)
                        Text("→").font(.caption)
                        Slider(value: $end, in: 0.1...duration)
                        Text(String(format: "%.1f", end)).font(.caption.monospacedDigit()).frame(width: 34)
                    }
                    Button("Save trimmed copy") { trim() }
                        .disabled(busy || end - start < 0.2)
                    if busy { ProgressView().controlSize(.small) }
                }
                if !status.isEmpty {
                    Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
    }

    private func load(_ url: URL) {
        source = url
        status = ""
        Task {
            do {
                duration = try await VideoTools.duration(of: url)
                start = 0
                end = duration
            } catch {
                status = "Error: \(error.localizedDescription)"
            }
        }
    }

    private func trim() {
        guard let source else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + "-trimmed." + source.pathExtension
        guard panel.runModal() == .OK, let output = panel.url else { return }
        busy = true
        status = ""
        Task {
            do {
                try await VideoTools.trim(source: source, start: start, end: end, to: output)
                status = "Saved → \(output.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([output])
            } catch {
                status = "Error: \(error.localizedDescription)"
            }
            busy = false
        }
    }
}

// MARK: - GIF

private struct GifSection: View {
    @State private var source: URL?
    @State private var duration: Double = 0
    @State private var start = 0.0
    @State private var end = 0.0
    @State private var width = 480.0
    @State private var fps = 12
    @State private var status = ""
    @State private var busy = false

    var body: some View {
        GroupBox("Convert to GIF") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button(source == nil ? "Choose video…" : source!.lastPathComponent) {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
                        panel.allowsMultipleSelection = false
                        guard panel.runModal() == .OK, let url = panel.url else { return }
                        load(url)
                    }
                    .lineLimit(1).truncationMode(.middle)
                    if source != nil {
                        Text(String(format: "%.1fs", duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if source != nil, duration > 0 {
                    HStack(spacing: 8) {
                        Text("Range").font(.caption)
                        Slider(value: $start, in: 0...max(duration - 0.2, 0.1))
                        Text(String(format: "%.1f", start)).font(.caption.monospacedDigit()).frame(width: 34)
                        Text("→").font(.caption)
                        Slider(value: $end, in: 0.1...duration)
                        Text(String(format: "%.1f", end)).font(.caption.monospacedDigit()).frame(width: 34)
                    }
                    HStack(spacing: 8) {
                        Text("Width").font(.caption)
                        Slider(value: $width, in: 240...720, step: 40)
                        Text("\(Int(width))px").font(.caption.monospacedDigit()).frame(width: 48)
                        Text("FPS").font(.caption)
                        Slider(value: Binding(get: { Double(fps) }, set: { fps = Int($0) }), in: 5...20, step: 1)
                        Text("\(fps)").font(.caption.monospacedDigit()).frame(width: 24)
                    }
                    Button("Save GIF") { convert() }
                        .disabled(busy || end - start < 0.2)
                    if busy { ProgressView().controlSize(.small) }
                }
                if !status.isEmpty {
                    Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
    }

    private func load(_ url: URL) {
        source = url
        status = ""
        Task {
            do {
                duration = try await VideoTools.duration(of: url)
                start = 0
                end = min(duration, 30) // GIFs grow fast; suggest a short default
            } catch {
                status = "Error: \(error.localizedDescription)"
            }
        }
    }

    private func convert() {
        guard let source else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gif]
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + ".gif"
        guard panel.runModal() == .OK, let output = panel.url else { return }
        busy = true
        status = "Encoding GIF…"
        Task {
            do {
                try await VideoTools.gif(source: source, start: start, end: end, width: CGFloat(width), fps: fps, to: output)
                status = "Saved → \(output.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([output])
            } catch {
                status = "Error: \(error.localizedDescription)"
            }
            busy = false
        }
    }
}
