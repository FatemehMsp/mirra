import Foundation

/// Builds, signs and launches WebDriverAgent on a real device — the only sanctioned way to
/// inject touches into iOS from a computer. Free Apple IDs sign for 7 days, so `build` doubles
/// as the renewal path.
public struct WDASetupService: Sendable {
    private let runner: any CommandRunning
    private let security = URL(fileURLWithPath: "/usr/bin/security")
    private let git = URL(fileURLWithPath: "/usr/bin/git")
    private let xcodebuild = URL(fileURLWithPath: "/usr/bin/xcodebuild")

    public static let repository = "https://github.com/appium/WebDriverAgent"

    /// All WDA sources and build output live under Application Support; nothing in the app bundle.
    public static var workRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mirra/WebDriverAgent", isDirectory: true)
    }
    public static var sourceURL: URL { workRoot.appendingPathComponent("WebDriverAgent", isDirectory: true) }
    public static var buildURL: URL { workRoot.appendingPathComponent("build", isDirectory: true) }
    public static var derivedDataURL: URL { buildURL.appendingPathComponent("derivedData", isDirectory: true) }

    public init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    // MARK: - Prerequisites

    /// The personal team ID from the codesigning identity Xcode created (e.g. in
    /// `Apple Development: me@icloud.com (AB12CD34E5)`); nil when no Apple ID is set up yet.
    public static func teamID(in securityOutput: String) -> String? {
        for line in securityOutput.split(separator: "\n") where line.contains("Apple Development") || line.contains("Apple Development:") {
            guard let open = line.lastIndex(of: "("), let close = line.lastIndex(of: ")"),
                  close > open else { continue }
            let team = String(line[line.index(after: open)..<close])
            if team.count == 10, team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil {
                return team
            }
        }
        return nil
    }

    /// Reads the signing identities from the keychain.
    public func signingTeam() async -> String? {
        let request = CommandRequest(executable: security, arguments: ["find-identity", "-v", "-p", "codesigning"], timeout: .seconds(15))
        guard let result = try? await runner.run(request) else { return nil }
        return Self.teamID(in: String(decoding: result.stdout, as: UTF8.self))
    }

    // MARK: - Build

    /// Clones WDA once; safe to call repeatedly.
    public func ensureCloned() async throws {
        let project = Self.sourceURL.appendingPathComponent("WebDriverAgent.xcodeproj")
        guard !FileManager.default.fileExists(atPath: project.path) else { return }
        try? FileManager.default.removeItem(at: Self.sourceURL)
        try FileManager.default.createDirectory(at: Self.workRoot, withIntermediateDirectories: true)
        let request = CommandRequest(executable: git, arguments: [
            "clone", "--depth", "1", Self.repository, Self.sourceURL.path
        ], timeout: .seconds(600))
        _ = try await runner.run(request)
    }

    /// Builds and signs the WDA runner for the device. With a free Apple ID this must be
    /// repeated every 7 days — `launch` reports the signing failure that triggers a renewal.
    public func build(udid: String, team: String) async throws -> String {
        try await ensureCloned()
        let request = CommandRequest(executable: xcodebuild, arguments: [
            "-project", Self.sourceURL.appendingPathComponent("WebDriverAgent.xcodeproj").path,
            "-scheme", "WebDriverAgentRunner",
            "-destination", "platform=iOS,id=\(udid)",
            "-derivedDataPath", Self.derivedDataURL.path,
            "DEVELOPMENT_TEAM=\(team)",
            "PRODUCT_BUNDLE_IDENTIFIER=\(Self.bundleID)",
            "-allowProvisioningUpdates",
            "-allowProvisioningDeviceRegistration",
            "build-for-testing",
        ], timeout: .seconds(900))
        do {
            _ = try await runner.run(request)
        } catch let CommandError.nonZeroExit(code, stderr) {
            throw SetupError.buildFailed(reason: Self.friendlyBuildError(stderr, code: code))
        }
        guard let xctestrun = Self.findXCTestRun(in: Self.derivedDataURL) else {
            throw SetupError.buildFailed(reason: "The build produced no .xctestrun file")
        }
        return xctestrun
    }

    /// A bundle ID unique to this app so a free Apple ID can register it (the default one is taken).
    public static let bundleID = "dev.mirra.wda.runner"

    /// Finds the built `WebDriverAgentRunner_iphoneos*.xctestrun`.
    public static func findXCTestRun(in derivedData: URL) -> String? {
        let products = derivedData.appendingPathComponent("Build/Products", isDirectory: true)
        let contents = (try? FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: nil)) ?? []
        return contents
            .filter { $0.pathExtension == "xctestrun" && $0.lastPathComponent.hasPrefix("WebDriverAgentRunner") }
            .first?.path
    }

    // MARK: - Launch

    /// Starts the WDA runner on the device. The process must stay alive for the server to keep
    /// running; the returned stream finishes when xcodebuild exits.
    public func launchStream(udid: String, xctestrun: String) -> AsyncThrowingStream<Data, Error> {
        runner.stream(CommandRequest(executable: xcodebuild, arguments: [
            "-xctestrun", xctestrun,
            "-destination", "platform=iOS,id=\(udid)",
            "-allowProvisioningUpdates",
            "test-without-building",
        ], timeout: .seconds(86_400)))
    }

    /// Maps xcodebuild failures to actionable guidance.
    public static func friendlyBuildError(_ stderr: String, code: Int32) -> String {
        if stderr.contains("No Account for Team") || stderr.contains("No profiles for") && stderr.contains("adding your account") {
            return "Xcode has no Apple ID for signing. Open Xcode → Settings → Accounts and add your Apple ID, then try again."
        }
        if stderr.contains("requires a development team") || stderr.contains("Signing for \"WebDriverAgentLib\" requires") {
            return "Signing failed — add your Apple ID in Xcode → Settings → Accounts."
        }
        if stderr.contains("is not registered on your team") || stderr.contains("cannot be registered to your development team") {
            return "The bundle ID is taken. This is a Mirra bug — please report it."
        }
        if stderr.contains("Unable to install") || stderr.contains("device is locked") || stderr.contains("please unlock") {
            return "Unlock the device and keep it connected, then try again."
        }
        if stderr.contains("developer mode") || stderr.contains("Developer Mode") {
            return "Enable Developer Mode on the device (Settings → Privacy & Security) and trust the developer app."
        }
        if stderr.contains("provisioning profile") && (stderr.contains("expired") || stderr.contains("no longer valid")) {
            return "The 7-day free signature expired — press Renew."
        }
        let firstMeaningful = stderr.split(separator: "\n").first(where: { !$0.isEmpty }) ?? "unknown error"
        return "Build failed (\(code)): \(String(firstMeaningful.prefix(200)))"
    }

    public enum SetupError: Error, LocalizedError {
        case buildFailed(reason: String)
        case noSigningTeam

        public var errorDescription: String? {
            switch self {
            case .buildFailed(let reason): return reason
            case .noSigningTeam: return "No Apple ID is set up for signing. Open Xcode → Settings → Accounts, add your Apple ID, then try again."
            }
        }
    }
}
