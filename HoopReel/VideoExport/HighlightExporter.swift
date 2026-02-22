import Foundation
import AVFoundation
import Combine

// MARK: - HighlightExporter

/// Builds an AVMutableComposition from a list of ClipRanges and exports
/// it to a temporary .mp4 file.  All published properties are updated on
/// the main actor so SwiftUI views can observe them directly.
///
/// Robustness notes
/// ────────────────
///  • Audio-less sources are handled automatically: if no audio track exists
///    only the video track is composed and exported.
///  • Clip ranges that exceed the source duration are clamped inside
///    buildHighlight; combined with EventEngine's own clamping this provides
///    double protection against out-of-bounds time ranges.
///  • cancelExport() stops the session and suppresses the error UI so the
///    UI returns to idle state without showing a failure message.
@MainActor
final class HighlightExporter: ObservableObject {

    // MARK: Published state

    @Published var progress: Float = 0
    @Published var isExporting: Bool = false
    @Published var exportedURL: URL?         // single-highlight result
    @Published var exportedURLs: [URL] = []  // multi-clip results
    @Published var errorMessage: String?

    // MARK: Private

    private var exportSession:      AVAssetExportSession?
    private var progressTimer:      Timer?
    private var wasCancelled        = false
    private var completedClipsCount = 0      // for multi-clip progress
    private var totalClipsCount     = 0

    // MARK: - Public API

    /// Kicks off an async export. Safe to call from any @MainActor context.
    func export(videoURL: URL, clipRanges: [ClipRange]) {
        guard !isExporting else { return }
        reset()
        isExporting = true

        Task {
            do {
                let url = try await buildHighlight(from: videoURL, clips: clipRanges)
                exportedURL = url
                progress    = 1.0
            } catch {
                // Suppress error display for user-initiated cancellations.
                if !wasCancelled {
                    errorMessage = error.localizedDescription
                }
            }
            stopProgressTimer()
            isExporting = false
        }
    }

    /// Exports each ClipRange as a separate HoopReel_Clip_NNN.mp4.
    /// Progress = (completedClips + currentClipFraction) / totalClips.
    func exportClips(inputURL: URL, clips: [ClipRange]) {
        guard !isExporting else { return }
        reset()
        isExporting = true

        Task {
            do {
                let urls = try await buildClips(from: inputURL, clips: clips)
                exportedURLs = urls
                progress     = 1.0
            } catch {
                if !wasCancelled { errorMessage = error.localizedDescription }
            }
            stopProgressTimer()
            isExporting = false
        }
    }

    /// Cancels a running export.  The UI returns to idle state without
    /// showing a failure message.
    func cancelExport() {
        guard isExporting else { return }
        wasCancelled = true
        exportSession?.cancelExport()
        // The Task's await will resume shortly with .cancelled status;
        // cleanup (stopProgressTimer, isExporting = false) happens there.
    }

    // MARK: - Build & Export

    private func buildHighlight(from videoURL: URL,
                                clips: [ClipRange]) async throws -> URL {

        // ── 1. Load asset metadata ──────────────────────────────────────────
        let asset     = AVURLAsset(url: videoURL)
        let duration  = try await asset.load(.duration)
        let assetSec  = CMTimeGetSeconds(duration)

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        guard let srcVideo = videoTracks.first else {
            throw ExportError.noVideoTrack
        }

        // ── 2. Build composition ────────────────────────────────────────────
        let composition = AVMutableComposition()

        guard let dstVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw ExportError.compositionFailed }

        // Audio is optional – if the source has no audio track we skip it
        // entirely rather than failing.
        let srcAudio = audioTracks.first
        let dstAudio: AVMutableCompositionTrack? = srcAudio.flatMap { _ in
            composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        }

        // ── 3. Insert clip time ranges ──────────────────────────────────────
        var cursor = CMTime.zero

        for clip in clips {
            // Double-clamp: EventEngine already clamped, but guard against
            // any ranges that arrive from other sources.
            let s = max(0.0,      clip.start)
            let e = min(assetSec, clip.end)
            guard e > s else { continue }

            let range = CMTimeRange(
                start:    CMTime(seconds: s,     preferredTimescale: 600),
                duration: CMTime(seconds: e - s, preferredTimescale: 600)
            )

            try dstVideo.insertTimeRange(range, of: srcVideo, at: cursor)

            if let sa = srcAudio, let da = dstAudio {
                try da.insertTimeRange(range, of: sa, at: cursor)
            }

            cursor = CMTimeAdd(cursor, range.duration)
        }

        guard CMTimeGetSeconds(cursor) > 0 else {
            throw ExportError.emptyComposition
        }

        // Preserve source video orientation (portrait / landscape).
        dstVideo.preferredTransform = try await srcVideo.load(.preferredTransform)

        // ── 4. Configure export session ─────────────────────────────────────
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HoopReel_\(UUID().uuidString).mp4")

        guard let session = AVAssetExportSession(
            asset:      composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else { throw ExportError.sessionFailed }

        session.outputURL                    = outURL
        session.outputFileType               = .mp4
        session.shouldOptimizeForNetworkUse  = true

        exportSession = session
        startProgressTimer()

        // ── 5. Export (wrap legacy callback API in a continuation) ──────────
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }

        guard session.status == .completed else {
            // Cancelled state is handled upstream in export() via wasCancelled.
            throw session.error ?? ExportError.exportFailed
        }

        return outURL
    }

    // MARK: - Multi-clip builder

    private func buildClips(from videoURL: URL, clips: [ClipRange]) async throws -> [URL] {
        let asset    = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let assetSec = CMTimeGetSeconds(duration)

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let srcVideo = videoTracks.first else { throw ExportError.noVideoTrack }
        let srcAudio = audioTracks.first

        let preferredTransform = try await srcVideo.load(.preferredTransform)

        totalClipsCount     = clips.count
        completedClipsCount = 0
        startProgressTimer()

        var results: [URL] = []

        for (idx, clip) in clips.enumerated() {
            guard !wasCancelled else { break }

            let s = max(0.0, clip.start)
            let e = min(assetSec, clip.end)
            guard e > s else { completedClipsCount += 1; continue }

            let range = CMTimeRange(
                start:    CMTime(seconds: s,     preferredTimescale: 600),
                duration: CMTime(seconds: e - s, preferredTimescale: 600)
            )

            // Single-clip composition
            let composition = AVMutableComposition()
            guard let dstVideo = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { throw ExportError.compositionFailed }

            dstVideo.preferredTransform = preferredTransform
            try dstVideo.insertTimeRange(range, of: srcVideo, at: .zero)

            if let sa = srcAudio,
               let dstAudio = composition.addMutableTrack(
                   withMediaType: .audio,
                   preferredTrackID: kCMPersistentTrackID_Invalid) {
                try dstAudio.insertTimeRange(range, of: sa, at: .zero)
            }

            let filename = String(format: "HoopReel_Clip_%03d.mp4", idx + 1)
            let outURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: outURL)

            guard let session = AVAssetExportSession(
                asset: composition,
                presetName: AVAssetExportPresetHighestQuality
            ) else { throw ExportError.sessionFailed }

            session.outputURL               = outURL
            session.outputFileType          = .mp4
            session.shouldOptimizeForNetworkUse = true

            exportSession = session   // progress timer and cancelExport() target this

            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously { cont.resume() }
            }

            if wasCancelled { break }

            guard session.status == .completed else {
                throw session.error ?? ExportError.exportFailed
            }

            results.append(outURL)
            completedClipsCount += 1
        }

        return results
    }

    // MARK: - Progress polling

    /// Schedules a 10 Hz timer to relay exportSession.progress → self.progress.
    /// Handles both single-highlight (totalClipsCount == 0) and multi-clip modes.
    private func startProgressTimer() {
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1,
                                            repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let session = self.exportSession else { return }
                if self.totalClipsCount > 0 {
                    let frac = (Float(self.completedClipsCount) + session.progress)
                               / Float(self.totalClipsCount)
                    self.progress = min(1.0, frac)
                } else {
                    self.progress = session.progress
                }
            }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    // MARK: - Helpers

    private func reset() {
        progress            = 0
        exportedURL         = nil
        exportedURLs        = []
        errorMessage        = nil
        exportSession       = nil
        wasCancelled        = false
        completedClipsCount = 0
        totalClipsCount     = 0
    }

    // MARK: - Errors

    enum ExportError: LocalizedError {
        case noVideoTrack
        case compositionFailed
        case emptyComposition
        case sessionFailed
        case exportFailed

        var errorDescription: String? {
            switch self {
            case .noVideoTrack:      return "视频中没有视频轨道"
            case .compositionFailed: return "无法创建合成轨道"
            case .emptyComposition:  return "所有片段均超出视频时长，无可合成内容"
            case .sessionFailed:     return "无法创建 AVAssetExportSession"
            case .exportFailed:      return "导出失败（原因未知）"
            }
        }
    }
}
