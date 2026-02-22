import Foundation
import AVFoundation
import CoreGraphics
import CoreVideo
import UIKit

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - SampledFrame
// ═══════════════════════════════════════════════════════════════════════════════

/// One decoded video frame, ready for CoreML inference.
///
/// `_sampleBuffer` is retained solely to keep `pixelBuffer` alive –
/// the two share the same backing memory via AVFoundation's buffer pool.
struct SampledFrame: @unchecked Sendable {
    // nonisolated(unsafe): pixel buffer is safe to access off MainActor because
    // SampledFrame is @unchecked Sendable and the backing memory is exclusively
    // owned by this value (alwaysCopiesSampleData = false but the CMSampleBuffer
    // is retained alongside it in _sampleBuffer).
    nonisolated(unsafe) let pixelBuffer: CVPixelBuffer
    let timeSeconds: Double
    let index:       Int
    fileprivate let _sampleBuffer: CMSampleBuffer

    // MARK: Convenience

    /// Shared CIContext avoids per-frame allocation overhead.
    nonisolated private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Converts the pixel buffer to a UIImage (for SwiftUI display).
    nonisolated func toUIImage() -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = Self.ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - VideoFrameSampler  (AVAssetReader · Step 3)
// ═══════════════════════════════════════════════════════════════════════════════

/// Decodes video frames via `AVAssetReader` at a target fps.
///
/// Frames that fall between sample points are skipped at the decode level
/// (read-and-discard), keeping memory constant regardless of source fps.
///
/// Usage:
/// ```swift
/// let sampler = VideoFrameSampler()
/// for try await frame in sampler.frames(from: url, fps: 12, maxSeconds: 10) {
///     let detections = try engine.detect(pixelBuffer: frame.pixelBuffer, ...)
/// }
/// ```
final class VideoFrameSampler: @unchecked Sendable {

    /// Returns an async stream of decoded frames at `fps`, stopping after
    /// `maxSeconds` from the start of the video.
    nonisolated func frames(
        from url:      URL,
        fps:           Double = 12,
        startSeconds:  Double = 0,
        maxSeconds:    Double = .infinity
    ) -> AsyncThrowingStream<SampledFrame, Error> {

        // bufferingOldest(2): at most 2 frames queued; if consumer is slower
        // than producer the *newest* decoded frame is dropped (avoids OOM).
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(2)) { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    let asset    = AVURLAsset(url: url)
                    let duration = try await asset.load(.duration)
                    let totalSec = CMTimeGetSeconds(duration)
                    let endSec   = min(totalSec, startSeconds + maxSeconds)
                    let spanSec  = max(0, endSec - startSeconds)

                    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                        throw SamplerError.noVideoTrack
                    }

                    // ── Configure reader ───────────────────────────────────
                    let reader = try AVAssetReader(asset: asset)
                    reader.timeRange = CMTimeRange(
                        start:    CMTime(seconds: startSeconds, preferredTimescale: 600),
                        duration: CMTime(seconds: spanSec, preferredTimescale: 600)
                    )

                    let outputSettings: [String: Any] = [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                    ]
                    let output = AVAssetReaderTrackOutput(
                        track:          track,
                        outputSettings: outputSettings
                    )
                    // Do NOT copy data – the pixel buffer shares memory with
                    // the CMSampleBuffer which we retain in SampledFrame.
                    output.alwaysCopiesSampleData = false
                    reader.add(output)

                    guard reader.startReading() else {
                        throw reader.error ?? SamplerError.readerFailed
                    }

                    // ── Decode & skip loop ─────────────────────────────────
                    let interval        = 1.0 / fps
                    var nextSampleTime  = startSeconds
                    var frameIndex      = 0

                    while reader.status == .reading {
                        try Task.checkCancellation()

                        guard let sampleBuffer = output.copyNextSampleBuffer() else { break }

                        let pts     = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                        let timeSec = CMTimeGetSeconds(pts)

                        // Skip frames until we reach the next target time.
                        guard timeSec >= nextSampleTime else { continue }

                        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                            continue
                        }

                        let frame = SampledFrame(
                            pixelBuffer:   pixelBuffer,
                            timeSeconds:   timeSec,
                            index:         frameIndex,
                            _sampleBuffer: sampleBuffer
                        )
                        continuation.yield(frame)

                        frameIndex     += 1
                        nextSampleTime  = startSeconds + Double(frameIndex) * interval
                    }

                    if reader.status == .failed, let error = reader.error {
                        continuation.finish(throwing: error)
                    } else {
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: Errors

    enum SamplerError: LocalizedError {
        case noVideoTrack
        case readerFailed

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "视频中未找到视频轨道"
            case .readerFailed: return "AVAssetReader 初始化失败"
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Legacy FrameSamplerProtocol (kept for ShotDetector backward compat)
// ═══════════════════════════════════════════════════════════════════════════════

/// Extracts CGImages from a video asset at a specified frame rate.
protocol FrameSamplerProtocol: Sendable {
    func sampleFrames(
        from asset:        AVAsset,
        fps:               Double,
        outputSize:        CGSize,
        progress:          @escaping @Sendable (Double) -> Void
    ) -> AsyncThrowingStream<(index: Int, timestamp: Double, image: CGImage), Error>
}

/// Legacy implementation using AVAssetImageGenerator (for ShotDetector).
final class AVFrameSampler: FrameSamplerProtocol {

    func sampleFrames(
        from asset:  AVAsset,
        fps:         Double,
        outputSize:  CGSize,
        progress:    @escaping @Sendable (Double) -> Void
    ) -> AsyncThrowingStream<(index: Int, timestamp: Double, image: CGImage), Error> {

        AsyncThrowingStream { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    let duration   = try await asset.load(.duration)
                    let totalSec   = CMTimeGetSeconds(duration)
                    let frameCount = Int(totalSec * fps)
                    guard frameCount > 0 else { continuation.finish(); return }

                    let generator = AVAssetImageGenerator(asset: asset)
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = outputSize
                    generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: CMTimeScale(fps))
                    generator.requestedTimeToleranceAfter  = CMTime(value: 1, timescale: CMTimeScale(fps))

                    let interval = 1.0 / fps
                    for i in 0 ..< frameCount {
                        let sec = Double(i) * interval
                        let t   = CMTime(seconds: sec, preferredTimescale: 600)
                        try Task.checkCancellation()
                        do {
                            // copyCGImage(at:actualTime:) is available since iOS 4;
                            // the async image(at:) overload requires iOS 16+.
                            let cgImage = try generator.copyCGImage(at: t, actualTime: nil)
                            continuation.yield((index: i, timestamp: sec, image: cgImage))
                        } catch { /* skip undecodable frames */ }
                        progress(Double(i + 1) / Double(frameCount))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
