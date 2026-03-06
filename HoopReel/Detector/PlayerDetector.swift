import Foundation
import AVFoundation
import UIKit
import CoreVideo

// MARK: - PlayerDetector

/// Orchestrates the player tracking + possession detection pipeline:
///   Inline AVAssetReader → VisionInferenceEngine (ball/hoop)
///                        → PlayerTracker (player)
///                        → PossessionRuleEngine (gain/loss)
///                        → [Event]
///
/// Mirrors `ShotDetector`'s synchronous frame loop to avoid frame dropping.
final class PlayerDetector {

    let playerTracker     = PlayerTracker()
    let possessionEngine  = PossessionRuleEngine()
    let shotRuleEngine    = ShotRuleEngine()

    /// Progress callback with:
    ///  - fraction: 0..1
    ///  - possessionDebug: PossessionRuleEngine.DebugState
    ///  - shotDebug: ShotRuleEngine.DebugState
    ///  - frame image: UIImage?
    ///  - detections: [Detection]
    ///  - tracked player: TrackedPlayer?
    typealias ProgressCallback = (
        Double,
        PossessionRuleEngine.DebugState,
        ShotRuleEngine.DebugState,
        UIImage?,
        [Detection],
        TrackedPlayer?
    ) -> Void

    /// Initialize the tracker from a tap point on a specific frame.
    ///
    /// Call this BEFORE `detectPossession(…)` so the tracker knows which
    /// player to follow.
    ///
    /// - Parameters:
    ///   - videoURL:     Local video file.
    ///   - tapPoint:     Normalized (top-left origin) tap location.
    ///   - atSeconds:    Time in the video where the user tapped.
    /// - Returns: The initial TrackedPlayer, or nil if no person found.
    func initializePlayer(
        videoURL: URL,
        tapPoint: CGPoint,
        atSeconds: Double
    ) async throws -> (TrackedPlayer?, UIImage?) {

        let asset = AVURLAsset(url: videoURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return (nil, nil)
        }

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start:    CMTime(seconds: atSeconds, preferredTimescale: 600),
            duration: CMTime(seconds: 1.0,       preferredTimescale: 600)
        )

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = true
        reader.add(output)

        guard reader.startReading() else { return (nil, nil) }

        // Read the first frame near the requested time
        guard let sampleBuffer = output.copyNextSampleBuffer(),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return (nil, nil)
        }

        let trackedPlayer = try playerTracker.initializeFromTap(
            pixelBuffer: pixelBuffer,
            tapPoint: tapPoint
        )

        // Create UIImage for display
        let uiImage = await Task.detached {
            let ci = CIImage(cvPixelBuffer: pixelBuffer)
            let ctx = CIContext(options: [.useSoftwareRenderer: false])
            return ctx.createCGImage(ci, from: ci.extent).map { UIImage(cgImage: $0) }
        }.value

        reader.cancelReading()

        return (trackedPlayer, uiImage)
    }

    /// Runs player tracking + possession detection on the video.
    ///
    /// - Parameters:
    ///   - videoURL:             Local file URL.
    ///   - fps:                  Frame sampling rate (default 12).
    ///   - startSeconds:        Start time in the video.
    ///   - maxDurationSeconds:   Stop after this many seconds (nil = full video).
    ///   - detectShots:          Also run ShotRuleEngine in parallel (default true).
    ///   - progress:             Called each frame with tracking state.
    /// - Returns: All detected events (gain + loss + optional makes) sorted by time.
    func detectPossession(
        videoURL: URL,
        fps: Double = 12,
        startSeconds: Double = 0,
        maxDurationSeconds: Double? = nil,
        detectShots: Bool = true,
        progress: @escaping ProgressCallback
    ) async throws -> [Event] {

        possessionEngine.reset()
        shotRuleEngine.reset()

        let inferenceEngine = try VisionInferenceEngine()

        // ── Video asset setup ─────────────────────────────────────────
        let asset    = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let totalSec = CMTimeGetSeconds(duration)
        let limitSec = maxDurationSeconds ?? (totalSec - startSeconds)
        let spanSec  = max(0, limitSec)

        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw PlayerDetectorError.noVideoTrack
        }

        // ── Configure AVAssetReader ───────────────────────────────────
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start:    CMTime(seconds: startSeconds, preferredTimescale: 600),
            duration: CMTime(seconds: spanSec,      preferredTimescale: 600)
        )

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = true
        reader.add(output)

        guard reader.startReading() else {
            throw reader.error ?? PlayerDetectorError.readerFailed
        }

        // ── Synchronous read → infer → track → consume loop ──────────
        let interval       = 1.0 / fps
        var nextSampleTime = startSeconds
        var frameIndex     = 0
        let ciContext       = CIContext(options: [.useSoftwareRenderer: false])

        while reader.status == .reading {
            try Task.checkCancellation()

            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }

            let pts     = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let timeSec = CMTimeGetSeconds(pts)

            guard timeSec >= nextSampleTime else { continue }

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                continue
            }

            // ── 1. YOLO inference (ball + hoop) ───────────────────────
            let detections: [Detection]
            do {
                detections = try await Task.detached {
                    try inferenceEngine.detect(
                        pixelBuffer: pixelBuffer,
                        timeSeconds: timeSec
                    )
                }.value
            } catch {
                detections = []
            }

            // ── 2. Player tracking ────────────────────────────────────
            let tracked: TrackedPlayer?
            do {
                tracked = try await Task.detached { [playerTracker] in
                    try playerTracker.processFrame(
                        pixelBuffer: pixelBuffer,
                        timeSeconds: timeSec
                    )
                }.value
            } catch {
                tracked = nil
            }

            // ── 3. Ball detection → possession engine ──────────────────
            let ballDet = detections
                .filter { $0.label == "Basketball" }
                .max(by: { $0.confidence < $1.confidence })
            let ballBox = ballDet?.rectTopLeft

            possessionEngine.consumeFrame(
                playerBox: tracked?.boundingBox,
                ballBox:   ballBox,
                timeSeconds: timeSec
            )

            // ── 4. Optional shot detection ────────────────────────────
            if detectShots {
                shotRuleEngine.consumeFrame(timeSeconds: timeSec, detections: detections)
            }

            // ── 5. Frame → UIImage ────────────────────────────────────
            let uiImage = await Task.detached {
                let ci = CIImage(cvPixelBuffer: pixelBuffer)
                return ciContext.createCGImage(ci, from: ci.extent)
                    .map { UIImage(cgImage: $0) }
            }.value

            let frac = min(1.0, (timeSec - startSeconds) / max(0.001, spanSec))
            progress(
                frac,
                possessionEngine.debugState,
                shotRuleEngine.debugState,
                uiImage,
                detections,
                tracked
            )

            frameIndex     += 1
            nextSampleTime  = startSeconds + Double(frameIndex) * interval
        }

        if reader.status == .failed, let error = reader.error {
            throw error
        }

        progress(1.0, possessionEngine.debugState, shotRuleEngine.debugState, nil, [], nil)
        possessionEngine.flushDiagnostics()
        shotRuleEngine.flushDiagnostics()

        // Combine possession events + shot events
        var allEvents = possessionEngine.detectedEvents
        if detectShots {
            allEvents.append(contentsOf: shotRuleEngine.detectedMakes)
        }

        return allEvents.sorted { $0.time < $1.time }
    }

    // MARK: Errors

    enum PlayerDetectorError: LocalizedError {
        case noVideoTrack
        case readerFailed

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "Video contains no video track"
            case .readerFailed: return "AVAssetReader failed to start"
            }
        }
    }
}
