import AVFoundation

/// Losslessly concatenates screenrecord segments into one mp4.
///
/// Segments of the same recording share codec parameters, so a passthrough export avoids
/// re-encoding. If the device rotated between segments the track dimensions differ and the
/// insert fails; the caller then keeps the clips as separate files instead of losing footage.
public enum ScreenRecordingStitcher {
    public static func stitch(segments: [URL], to output: URL) async throws {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw StitchError.compositionFailed
        }
        var cursor = CMTime.zero
        for segment in segments {
            let asset = AVURLAsset(url: segment)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let source = tracks.first else { throw StitchError.noVideoTrack(segment) }
            let duration = try await asset.load(.duration)
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: cursor)
            cursor = cursor + duration
        }
        guard let export = AVAssetExportSession(asset: composition, presetName: "AVAssetExportPresetPassthrough") else {
            throw StitchError.compositionFailed
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            export.outputURL = output
            export.outputFileType = .mp4
            export.exportAsynchronously {
                if let error = export.error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    public enum StitchError: Error, LocalizedError {
        case compositionFailed
        case noVideoTrack(URL)

        public var errorDescription: String? {
            switch self {
            case .compositionFailed: return "Could not build the merged recording"
            case .noVideoTrack(let url): return "Segment has no video track: \(url.lastPathComponent)"
            }
        }
    }
}
