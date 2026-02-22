import Foundation
import AVFoundation
import UIKit
import CoreVideo

// MARK: - ShotDetector

/// Orchestrates the full-video shot detection pipeline:
///   Inline AVAssetReader → VisionInferenceEngine → ShotRuleEngine → [Event]
///
/// Frames are decoded and processed **synchronously** — each frame is read,
/// inferred, and consumed by the rule engine before the next one is decoded.
/// This eliminates frame-dropping caused by AsyncThrowingStream buffer overflow
/// (the old VideoFrameSampler approach dropped >95% of frames on simulator
/// because the producer out-ran the consumer with a tiny 2-frame buffer).
final class ShotDetector {

    let ruleEngine = ShotRuleEngine()

    /// Runs make detection on the video.
    ///
    /// - Parameters:
    ///   - videoURL:             Local file URL.
    ///   - fps:                  Frame sampling rate (default 12).
    ///   - maxDurationSeconds:   Stop after this many seconds (`nil` = full video).
    ///   - progress:             Called each frame with (fraction, debugState, UIImage?, detections).
    /// - Returns: Detected make events sorted ascending by time.
    func detectMakes(
        videoURL: URL,
        fps: Double = 12,
        startSeconds: Double = 0,
        maxDurationSeconds: Double? = nil,
        roiRectNormalized: CGRect? = nil,
        progress: @escaping (Double, ShotRuleEngine.DebugState, UIImage?, [Detection]) -> Void
    ) async throws -> [Event] {

        ruleEngine.reset()

        let engine = try VisionInferenceEngine()

        // ── Video asset setup ───────────────────────────────────────────
        let asset    = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let totalSec = CMTimeGetSeconds(duration)
        let limitSec = maxDurationSeconds ?? (totalSec - startSeconds)
        let spanSec  = max(0, limitSec)

        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw DetectorError.noVideoTrack
        }

        // Cap fps on simulator to avoid overwhelming the slow CoreML runtime
        #if targetEnvironment(simulator)
        let effectiveFps = min(fps, 3)
        #else
        let effectiveFps = fps
        #endif

        // ── Configure AVAssetReader (inline, no async buffer) ───────────
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start:    CMTime(seconds: startSeconds, preferredTimescale: 600),
            duration: CMTime(seconds: spanSec,      preferredTimescale: 600)
        )

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let output = AVAssetReaderTrackOutput(
            track:          track,
            outputSettings: outputSettings
        )
        // Copy pixel data so the buffer-pool can reclaim the original
        // immediately — one extra ~3.7 MB copy per frame is fine when
        // processing synchronously (only one live copy at a time).
        output.alwaysCopiesSampleData = true
        reader.add(output)

        guard reader.startReading() else {
            throw reader.error ?? DetectorError.readerFailed
        }

        // ── Synchronous read → infer → consume loop ─────────────────────
        let interval       = 1.0 / effectiveFps
        var nextSampleTime = startSeconds
        var frameIndex     = 0
        let ciContext       = CIContext(options: [.useSoftwareRenderer: false])

        while reader.status == .reading {
            try Task.checkCancellation()

            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }

            let pts     = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let timeSec = CMTimeGetSeconds(pts)

            // Sub-sample: skip native frames between target timestamps
            guard timeSec >= nextSampleTime else { continue }

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                continue
            }

            // ── Inference (off MainActor) ───────────────────────────────
            let detections: [Detection]
            do {
                detections = try await Task.detached {
                    try engine.detect(
                        pixelBuffer:       pixelBuffer,
                        timeSeconds:       timeSec,
                        roiRectNormalized: roiRectNormalized
                    )
                }.value
            } catch {
                detections = []
            }

            // ── Rule engine (lightweight) ───────────────────────────────
            ruleEngine.consumeFrame(timeSeconds: timeSec, detections: detections)

            // ── Frame → UIImage (off MainActor) ─────────────────────────
            let uiImage = await Task.detached {
                let ci = CIImage(cvPixelBuffer: pixelBuffer)
                return ciContext.createCGImage(ci, from: ci.extent)
                    .map { UIImage(cgImage: $0) }
            }.value

            let frac = min(1.0, timeSec / max(0.001, limitSec))
            progress(frac, ruleEngine.debugState, uiImage, detections)

            frameIndex     += 1
            nextSampleTime  = startSeconds + Double(frameIndex) * interval
        }

        if reader.status == .failed, let error = reader.error {
            throw error
        }

        progress(1.0, ruleEngine.debugState, nil, [])
        ruleEngine.flushDiagnostics()

        return ruleEngine.detectedMakes.sorted { $0.time < $1.time }
    }

    // MARK: Errors

    enum DetectorError: LocalizedError {
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
