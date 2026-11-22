import Foundation
import CryptoKit

/// Self-update against GitHub Releases: check the latest release, compare versions, download the
/// DMG (with progress), verify its sha256, and build the replace-and-relaunch install script.
public struct UpdateService: Sendable {
    public struct Release: Sendable, Equatable {
        public let version: String // without the leading "v"
        public let dmgURL: URL
        public let sha256URL: URL?
    }

    public enum UpdateError: Error, LocalizedError {
        case noDMGAsset
        case checksumMismatch
        case currentVersionUnknown

        public var errorDescription: String? {
            switch self {
            case .noDMGAsset: return "The release has no Mirra.dmg asset"
            case .checksumMismatch: return "The downloaded file failed its checksum verification"
            case .currentVersionUnknown: return "Could not read the running app's version"
            }
        }
    }

    public static let releasesAPI = URL(string: "https://api.github.com/repos/FatemehMsp/mirra/releases/latest")!
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Version comparison

    /// The running app's marketing version, e.g. "0.4.0".
    public static func currentVersion() -> String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// `"v0.4.1"` → `[0, 4, 1]`; non-numeric parts are ignored.
    public static func parseVersion(_ version: String) -> [Int] {
        var cleaned = version
        if cleaned.hasPrefix("v") || cleaned.hasPrefix("V") { cleaned.removeFirst() }
        return cleaned.split(separator: ".").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Component-wise semver comparison; a missing component counts as 0.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let candidateParts = parseVersion(candidate)
        let currentParts = parseVersion(current)
        guard !candidateParts.isEmpty, !currentParts.isEmpty else { return false }
        for index in 0..<max(candidateParts.count, currentParts.count) {
            let c = index < candidateParts.count ? candidateParts[index] : 0
            let m = index < currentParts.count ? currentParts[index] : 0
            if c != m { return c > m }
        }
        return false
    }

    // MARK: - Latest release

    /// Fetches the newest published release; nil when it carries no Mirra.dmg asset.
    public func latestRelease() async throws -> Release? {
        var request = URLRequest(url: Self.releasesAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, _) = try await session.data(for: request)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = root["tag_name"] as? String,
              let assets = root["assets"] as? [[String: Any]] else { return nil }
        var dmgURL: URL?
        var sha256URL: URL?
        for asset in assets {
            guard let name = asset["name"] as? String, let urlString = asset["browser_download_url"] as? String else { continue }
            if name == "Mirra.dmg" { dmgURL = URL(string: urlString) }
            if name == "Mirra.dmg.sha256" { sha256URL = URL(string: urlString) }
        }
        guard let dmgURL else { return nil }
        return Release(version: tag, dmgURL: dmgURL, sha256URL: sha256URL)
    }

    // MARK: - Download

    /// Downloads the DMG to `destination`, reporting progress as a 0…1 fraction.
    public func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let delegate = DownloadDelegate(destination: destination, progress: progress, continuation: continuation)
            let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
            delegate.session = session
            session.downloadTask(with: url).resume()
        }
    }

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let destination: URL
        let progress: @Sendable (Double) -> Void
        let continuation: CheckedContinuation<Void, Error>
        weak var session: URLSession?

        init(destination: URL, progress: @escaping @Sendable (Double) -> Void, continuation: CheckedContinuation<Void, Error>) {
            self.destination = destination
            self.progress = progress
            self.continuation = continuation
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            try? FileManager.default.removeItem(at: destination)
            do {
                try FileManager.default.moveItem(at: location, to: destination)
                continuation.resume()
            } catch {
                continuation.resume(throwing: error)
            }
            session.finishTasksAndInvalidate()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let error else { return } // success is reported by didFinishDownloadingTo
            continuation.resume(throwing: error)
            session.finishTasksAndInvalidate()
        }
    }

    /// Checks the downloaded DMG against the release's `Mirra.dmg.sha256` asset.
    public func verify(dmg: URL, sha256URL: URL?) async throws {
        guard let sha256URL else { return }
        let (data, _) = try await session.data(from: sha256URL)
        guard let expected = Self.expectedChecksum(String(decoding: data, as: UTF8.self)) else { return }
        let fileData = try Data(contentsOf: dmg)
        let actual = SHA256.hash(data: fileData).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw UpdateError.checksumMismatch }
    }

    /// The hash from a `"<sha256>  Mirra.dmg"` line.
    public static func expectedChecksum(_ contents: String) -> String? {
        contents
            .split(separator: "\n")
            .first?
            .split(separator: " ")
            .first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }

    // MARK: - Install

    /// Mounts the DMG, replaces `/Applications/Mirra.app` and relaunches. Run detached after the
    /// app has quit; the script waits a beat first so the running instance can exit.
    public static func installScript(dmgPath: String) -> String {
        """
        #!/bin/zsh
        sleep 1
        MP="$(mktemp -d)"
        /usr/bin/hdiutil attach -nobrowse -quiet -mountpoint "$MP" \(dmgPath)
        APP="$(find "$MP" -maxdepth 2 -name 'Mirra.app' -type d | head -1)"
        if [ -z "$APP" ]; then
          /usr/bin/hdiutil detach "$MP" -quiet
          exit 1
        fi
        rm -rf /Applications/Mirra.app
        cp -R "$APP" /Applications/Mirra.app
        /usr/bin/hdiutil detach "$MP" -quiet
        /usr/bin/open /Applications/Mirra.app
        """
    }
}
