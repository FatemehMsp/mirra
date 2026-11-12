import AVFoundation
import QuartzCore

/// Burns touch markers into a finished recording: a pulsing circle for taps and a fading path
/// for swipes. Used because Android never renders injected (mirrored) touches, and screenrecord
/// on some devices does not capture the "Show taps" indicator either.
public enum TouchMarkerRenderer {
    /// Renders `events` over `source` into `output`. `recordingStart` anchors the event
    /// timestamps to the video timeline; `startupLag` compensates for screenrecord's warm-up.
    public static func render(events: [TouchEvent], into source: URL, recordingStart: Date, startupLag: TimeInterval = 0.35, to output: URL) async throws {
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw RenderError.noVideoTrack }
        let duration = try await asset.load(.duration)
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let transformed = naturalSize.applying(transform)
        let renderSize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
        guard renderSize.width > 0, renderSize.height > 0 else { throw RenderError.noVideoTrack }

        let composition = AVMutableVideoComposition()
        composition.renderSize = renderSize
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        instruction.layerInstructions = [layerInstruction]
        composition.instructions = [instruction]

        let videoLayer = CALayer()
        videoLayer.frame = CGRect(origin: .zero, size: renderSize)
        let overlay = CALayer()
        overlay.frame = CGRect(origin: .zero, size: renderSize)
        overlay.addSublayer(markersLayer(events: events, recordingStart: recordingStart, startupLag: startupLag, size: renderSize))
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: renderSize)
        parent.addSublayer(videoLayer)
        parent.addSublayer(overlay)
        composition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parent
        )

        guard let export = AVAssetExportSession(asset: asset, presetName: "AVAssetExportPresetHighestQuality") else {
            throw RenderError.exportSessionFailed
        }
        export.videoComposition = composition
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            export.outputURL = output
            export.outputFileType = .mp4
            export.exportAsynchronously {
                if let error = export.error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    /// All marker layers. CoreAnimation's origin is the video frame's bottom-left corner,
    /// so device y is flipped.
    private static func markersLayer(events: [TouchEvent], recordingStart: Date, startupLag: TimeInterval, size: CGSize) -> CALayer {
        let layer = CALayer()
        let scale = size.width / 1080
        for event in events {
            let offset = max(0, event.timestamp.timeIntervalSince(recordingStart) - startupLag)
            switch event.kind {
            case .tap(let x, let y):
                layer.addSublayer(tapLayer(x: x, y: y, at: offset, scale: scale, size: size))
            case .swipe(let points):
                layer.addSublayer(swipeLayer(points: points, at: offset, scale: scale, size: size))
            }
        }
        return layer
    }

    private static func tapLayer(x: Double, y: Double, at offset: TimeInterval, scale: Double, size: CGSize) -> CALayer {
        let radius = 34 * scale
        let circle = CALayer()
        circle.frame = CGRect(x: x - radius, y: size.height - y - radius, width: radius * 2, height: radius * 2)
        circle.cornerRadius = radius
        circle.backgroundColor = MarkerColors.white60
        circle.borderColor = MarkerColors.white
        circle.borderWidth = 2.5 * scale
        circle.opacity = 0

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0, 1, 1, 0]
        opacity.keyTimes = [0, 0.15, 0.6, 1]
        opacity.duration = 0.7
        opacity.beginTime = offset
        opacity.fillMode = .both
        circle.add(opacity, forKey: "pulse")

        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [0.5, 1.2, 1.0]
        pop.keyTimes = [0, 0.2, 1]
        pop.duration = 0.7
        pop.beginTime = offset
        pop.fillMode = .both
        circle.add(pop, forKey: "pop")
        return circle
    }

    private static func swipeLayer(points: [(x: Double, y: Double)], at offset: TimeInterval, scale: Double, size: CGSize) -> CALayer {
        let shape = CAShapeLayer()
        let path = CGMutablePath()
        let flipped = points.map { CGPoint(x: $0.x, y: size.height - $0.y) }
        guard let first = flipped.first else { return shape }
        path.move(to: first)
        flipped.dropFirst().forEach { path.addLine(to: $0) }
        shape.path = path
        shape.strokeColor = MarkerColors.white
        shape.fillColor = nil
        shape.lineWidth = 10 * scale
        shape.lineCap = .round
        shape.lineJoin = .round
        shape.opacity = 0

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0, 0.95, 0.95, 0]
        opacity.keyTimes = [0, 0.1, 0.65, 1]
        opacity.duration = 0.9
        opacity.beginTime = offset
        opacity.fillMode = .both
        shape.add(opacity, forKey: "fade")
        return shape
    }

    public enum RenderError: Error, LocalizedError {
        case noVideoTrack
        case exportSessionFailed

        public var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "The recording has no video track"
            case .exportSessionFailed: return "Could not create the export session"
            }
        }
    }
}

/// CGColor constants without importing AppKit into the core module.
private enum MarkerColors {
    static let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    static let white60 = CGColor(red: 1, green: 1, blue: 1, alpha: 0.6)
}
