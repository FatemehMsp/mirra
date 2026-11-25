import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Post-recording media utilities: lossless trimming and GIF export.
public enum VideoTools {
    // MARK: - Trim

    /// Trims `source` to `[start, end)` seconds with a passthrough export (no re-encode).
    public static func trim(source: URL, start: Double, end: Double, to output: URL) async throws {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        let clampedStart = max(0, min(start, seconds))
        let clampedEnd = max(clampedStart, min(end, seconds))
        guard clampedEnd - clampedStart > 0.1 else { throw VideoToolsError.badRange }

        let composition = AVMutableComposition()
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let sourceTrack = tracks.first else { throw VideoToolsError.noVideoTrack }
        guard let target = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw VideoToolsError.noVideoTrack }
        let range = CMTimeRange(
            start: CMTime(seconds: clampedStart, preferredTimescale: 600),
            end: CMTime(seconds: clampedEnd, preferredTimescale: 600)
        )
        try target.insertTimeRange(range, of: sourceTrack, at: .zero)

        // Audio, when present, follows the same range.
        if let audio = try await asset.loadTracks(withMediaType: .audio).first,
           let targetAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? targetAudio.insertTimeRange(range, of: audio, at: .zero)
        }

        guard let export = AVAssetExportSession(asset: composition, presetName: "AVAssetExportPresetPassthrough") else {
            throw VideoToolsError.exportFailed
        }
        export.outputFileType = source.pathExtension.lowercased() == "mov" ? .mov : .mp4
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            export.outputURL = output
            export.exportAsynchronously {
                if let error = export.error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    /// Total duration in seconds, for the trim UI.
    public static func duration(of source: URL) async throws -> Double {
        let asset = AVURLAsset(url: source)
        return CMTimeGetSeconds(try await asset.load(.duration))
    }

    // MARK: - GIF

    /// Exports `[start, end)` seconds of `source` as a GIF at `width` pixels and `fps` frames.
    /// GIFs have no audio; frames are re-encoded via ImageIO.
    public static func gif(source: URL, start: Double, end: Double, width: CGFloat, fps: Int, to output: URL) async throws {
        let asset = AVURLAsset(url: source)
        let seconds = CMTimeGetSeconds(try await asset.load(.duration))
        let clampedStart = max(0, min(start, seconds))
        let clampedEnd = max(clampedStart, min(end, seconds))
        guard clampedEnd - clampedStart > 0.1 else { throw VideoToolsError.badRange }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: width, height: width * 8) // cap height for tall videos
        let interval = 1.0 / Double(max(1, fps))

        let fileProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0,
            ],
        ]
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, 1, nil)
        else { throw VideoToolsError.exportFailed }
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)

        var time = clampedStart
        while time < clampedEnd {
            let frame = try generator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil)
            let frameProperties: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: interval,
                ],
            ]
            CGImageDestinationAddImage(destination, frame, frameProperties as CFDictionary)
            time += interval
        }
        guard CGImageDestinationFinalize(destination) else { throw VideoToolsError.exportFailed }
    }

    public enum VideoToolsError: Error, LocalizedError {
        case badRange
        case noVideoTrack
        case exportFailed

        public var errorDescription: String? {
            switch self {
            case .badRange: return "The time range is empty"
            case .noVideoTrack: return "The file has no video track"
            case .exportFailed: return "Export failed"
            }
        }
    }
}
