import SwiftUI
import PhotosUI
import AVFoundation
import AVKit
import UniformTypeIdentifiers

// MARK: - VideoTransferable

/// Bridges PhotosPickerItem → local temp file URL via Transferable.
/// Uses FileRepresentation so the video is never fully loaded into memory.
struct VideoTransferable: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).mov")
            try FileManager.default.copyItem(at: received.file, to: dest)
            return VideoTransferable(url: dest)
        }
    }
}

// MARK: - ContentView

struct ContentView: View {

    // MARK: Persisted settings (same AppStorage keys as SettingsView)

    @AppStorage("preSeconds")      private var preSeconds:      Double = 4.0
    @AppStorage("postSeconds")     private var postSeconds:     Double = 2.0
    @AppStorage("mergeGapSeconds") private var mergeGapSeconds: Double = 2.0

    // MARK: State – Phase 1

    @StateObject private var exporter = HighlightExporter()

    @State private var selectedItem:  PhotosPickerItem?
    @State private var videoURL:      URL?
    @State private var events:        [Event]     = []
    @State private var clipRanges:    [ClipRange] = []   // merged — 集锦 / UI list
    @State private var rawRanges:     [ClipRange] = []   // one-per-event — 多段导出
    @State private var isLoadingVideo = false
    @State private var showShare      = false
    @State private var showAlert      = false
    @State private var alertMessage   = ""
    @State private var showSettings    = false
    @State private var showEventEditor = false

    // MARK: State – Player

    @State private var player:      AVPlayer?
    @State private var previewTask: Task<Void, Never>?

    // MARK: State – Detection (shared between Preview & Full)

    @State private var showDebugOverlay     = true
    @State private var isRunningDetection   = false
    @State private var detectionProgress:   Double = 0
    @State private var detectionTimeLabel   = ""
    @State private var currentFrameImage:   UIImage?
    @State private var currentDetections:   [Detection] = []
    @State private var detectionTask:       Task<Void, Never>?
    @State private var detectionStats       = ""

    // MARK: State – Full Detection (Step 4)

    @State private var isFullDetection      = false
    @State private var ruleEngineDebug      = ShotRuleEngine.DebugState()
    @State private var detectionMaxSeconds: Double = 10

    // MARK: State – Export Mode + Preset

    @State private var exportMode:        ExportMode   = .highlight
    @State private var selectedPreset:    ExportPreset = .standard
    @State private var showClipsResult    = false       // multi-clip result sheet
    @State private var droppedEventCount  = 0           // events beyond video duration

    // MARK: State – Player Tracking

    enum DetectionMode: String, CaseIterable {
        case shotDetection  = "shot"
        case playerTracking = "player"
    }

    @State private var detectionMode:            DetectionMode = .shotDetection
    @State private var showPlayerSelectionSheet = false
    @State private var selectedPlayerPoint:      CGPoint?      = nil
    @State private var trackedPlayerBox:         CGRect?       = nil
    @State private var trackedPlayerInitial:     TrackedPlayer? = nil
    @State private var possessionDebug          = PossessionRuleEngine.DebugState()

    // MARK: Language

    @EnvironmentObject private var langMgr: LanguageManager
    private func t(_ key: String) -> String { langMgr.tr(key) }

    // MARK: Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    heroSection
                    pickerSection

                    // ── Video / Detection Preview ─────────────────────────
                    if isRunningDetection || currentFrameImage != nil || player != nil {
                        playerOrDetectionSection
                    }

                    // ── Detection controls ─────────────────────────────────
                    if videoURL != nil {
                        detectionControlsSection
                    }

                    if isRunningDetection {
                        detectionProgressSection
                    }

                    infoSection

                    if !events.isEmpty {
                        eventListSection
                    }

                    if !clipRanges.isEmpty {
                        rangeListSection
                    }

                    if exporter.isExporting {
                        progressSection
                    }

                    if let errMsg = exporter.errorMessage, !exporter.isExporting {
                        retrySection(message: errMsg)
                    }

                    presetSection
                    exportButton
                }
                .padding(20)
            }
            .navigationTitle("HoopReel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
        // ── Side-effects ──────────────────────────────────────────────────────
        .onChange(of: selectedItem) { _, newItem in
            Task { await handleSelection(newItem) }
        }
        .onChange(of: exporter.exportedURL)  { _, url  in if url  != nil  { showShare      = true } }
        .onChange(of: exporter.exportedURLs) { _, urls in if !urls.isEmpty { showClipsResult = true } }
        .onChange(of: preSeconds)        { _, _ in Task { await recomputeClips() } }
        .onChange(of: postSeconds)       { _, _ in Task { await recomputeClips() } }
        .onChange(of: mergeGapSeconds)   { _, _ in Task { await recomputeClips() } }
        // Preset change → write to @AppStorage → existing handlers fire recomputeClips
        .onChange(of: selectedPreset) { _, preset in
            preSeconds      = preset.pre
            postSeconds     = preset.post
            mergeGapSeconds = preset.mergeGap
        }
        // ── Sheets / alerts ───────────────────────────────────────────────────
        .sheet(isPresented: $showShare) {
            if let url = exporter.exportedURL {
                ShareSheet(activityItems: [url])
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(langMgr)
        }
        .sheet(isPresented: $showEventEditor) {
            EventEditorView(
                events:     $events,
                clipRanges: $clipRanges,
                videoURL:   videoURL,
                onChanged:  { await recomputeClips() }
            )
            .environmentObject(langMgr)
        }
        .sheet(isPresented: $showClipsResult) {
            clipsResultSheet
        }
        .sheet(isPresented: $showPlayerSelectionSheet) {
            if let url = videoURL {
                PlayerSelectionSheet(
                    videoURL: url,
                    atSeconds: player?.currentTime().seconds ?? 0
                ) { confirmed, point in
                    if let confirmed {
                        trackedPlayerInitial = confirmed
                        trackedPlayerBox     = confirmed.boundingBox
                        selectedPlayerPoint  = point
                    }
                }
                .environmentObject(langMgr)
            }
        }
        .alert(t("alert_title"), isPresented: $showAlert) {
            Button(t("alert_ok"), role: .cancel) {}
        } message: {
            Text(verbatim: alertMessage)
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Subviews
    // ═══════════════════════════════════════════════════════════════════════════

    private var heroSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "basketball.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text(t("subtitle"))
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    private var pickerSection: some View {
        PhotosPicker(selection: $selectedItem, matching: .videos) {
            HStack(spacing: 10) {
                if isLoadingVideo {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: videoURL == nil
                          ? "video.badge.plus"
                          : "checkmark.circle.fill")
                }
                Text(isLoadingVideo    ? t("loading")
                     : videoURL == nil ? t("select_video")
                                       : t("reselect_video"))
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(14)
        }
        .buttonStyle(.plain)
        .disabled(isLoadingVideo || exporter.isExporting || isRunningDetection)
    }

    // ── Player / Detection preview ──────────────────────────────────────────

    /// Shows either the detection frame preview (with overlay) or the AVKit player.
    private var playerOrDetectionSection: some View {
        ZStack {
            if let frameImage = currentFrameImage {
                detectionFramePreview(image: frameImage)
            } else if let player {
                normalPlayerView(player: player)
            }
        }
        .frame(height: 210)
        .cornerRadius(12)
        .clipped()
    }

    private func detectionFramePreview(image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .overlay {
                if showDebugOverlay {
                    GeometryReader { geo in
                        DetectionOverlayView(
                            detections: currentDetections,
                            imageSize:  image.size,
                            viewSize:   geo.size,
                            debugState: isFullDetection ? ruleEngineDebug : nil,
                            trackedPlayerBox: trackedPlayerBox,
                            possessionDebug: detectionMode == .playerTracking ? possessionDebug : nil
                        )
                    }
                }
            }
            .overlay {
                if detectionMode == .playerTracking && trackedPlayerBox != nil {
                    PlayerSelectorView(
                        trackedPlayerBox: trackedPlayerBox,
                        possessionState:  possessionDebug.possessionState
                    )
                    .environmentObject(langMgr)
                }
            }
            .overlay(alignment: .topLeading) {
                if !detectionTimeLabel.isEmpty {
                    Text(detectionTimeLabel)
                        .font(.caption.monospacedDigit().bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.65))
                        .foregroundStyle(.white)
                        .cornerRadius(5)
                        .padding(6)
                }
            }
            .overlay(alignment: .topTrailing) {
                if !currentDetections.isEmpty {
                    let ballCount = currentDetections.filter { $0.label == "Basketball" }.count
                    let hoopCount = currentDetections.filter { $0.label == "Basketball Hoop" }.count
                    Text("🏀\(ballCount) 🏟\(hoopCount)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.ultraThinMaterial)
                        .cornerRadius(5)
                        .padding(6)
                }
            }
    }

    private func normalPlayerView(player: AVPlayer) -> some View {
        VideoPlayer(player: player)
            .overlay(alignment: .topTrailing) {
                Text(t("preview_label"))
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial)
                    .cornerRadius(6)
                    .padding(8)
            }
    }

    // ── Detection controls ──────────────────────────────────────────────────

    private var detectionControlsSection: some View {
        VStack(spacing: 10) {
            // ── Detection mode picker ─────────────────────────────────
            Picker("Mode", selection: $detectionMode) {
                Text(t("mode_shot_detect")).tag(DetectionMode.shotDetection)
                Text(t("mode_player_track")).tag(DetectionMode.playerTracking)
            }
            .pickerStyle(.segmented)
            .onChange(of: detectionMode) { _, _ in
                // Reset player tracking state when switching modes
                selectedPlayerPoint  = nil
                trackedPlayerBox     = nil
                trackedPlayerInitial = nil
                possessionDebug      = PossessionRuleEngine.DebugState()
            }

            // Toggle row
            Toggle(isOn: $showDebugOverlay) {
                Label(t("debug_overlay"), systemImage: "rectangle.dashed")
                    .font(.callout)
            }
            .tint(.orange)

            // Buttons row
            if isRunningDetection {
                // Stop button
                Button(role: .destructive) {
                    stopDetection()
                } label: {
                    Label(t("stop_detection"), systemImage: "stop.circle.fill")
                        .font(.callout.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else if detectionMode == .shotDetection {
                // ── Shot detection buttons ─────────────────────────────
                HStack(spacing: 10) {
                    Button {
                        runDetectionPreview()
                    } label: {
                        Label(t("preview_10s"), systemImage: "viewfinder.rectangular")
                            .font(.callout.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .disabled(videoURL == nil || exporter.isExporting)

                    Button {
                        runQuickDetection()
                    } label: {
                        Label(t("detect_10s"), systemImage: "sparkle.magnifyingglass")
                            .font(.callout.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.mint)
                    .disabled(videoURL == nil || exporter.isExporting)
                }

                Button {
                    runFullDetection()
                } label: {
                    Label(t("auto_detect_full"), systemImage: "sparkle.magnifyingglass")
                        .font(.callout.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(videoURL == nil || exporter.isExporting)
            } else {
                // ── Player tracking buttons ────────────────────────────
                playerTrackingControls
            }

            // Stats after detection finishes
            if !isRunningDetection && !detectionStats.isEmpty {
                Text(detectionStats)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    /// Player tracking mode buttons: select player → start tracking.
    private var playerTrackingControls: some View {
        VStack(spacing: 10) {
            // Step 1: Select player
            HStack(spacing: 10) {
                Button {
                    enterPlayerSelectionMode()
                } label: {
                    Label(
                        trackedPlayerInitial == nil ? t("select_player") : t("reselect_player"),
                        systemImage: "person.crop.rectangle"
                    )
                    .font(.callout.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .disabled(videoURL == nil || exporter.isExporting)
            }

            // Player selected indicator
            if trackedPlayerInitial != nil {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(t("player_selected"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Step 2: Start tracking
            Button {
                runPlayerTracking()
            } label: {
                Label(t("start_tracking"), systemImage: "figure.run")
                    .font(.callout.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(videoURL == nil || trackedPlayerInitial == nil || exporter.isExporting)
        }
    }

    private var detectionProgressSection: some View {
        VStack(spacing: 6) {
            ProgressView(value: detectionProgress)
                .tint(detectionMode == .playerTracking ? .cyan : (isFullDetection ? .green : .purple))
                .animation(.linear(duration: 0.08), value: detectionProgress)
            Text(String(format: "%@ %.1f / %.0f s",
                        detectionMode == .playerTracking
                            ? t("detecting_possession")
                            : (isFullDetection ? t("detecting_makes") : t("detecting")),
                        detectionProgress * detectionMaxSeconds,
                        detectionMaxSeconds))
                .font(.caption)
                .foregroundStyle(.secondary)

            // During full detection show live makes count
            if detectionMode == .shotDetection && isFullDetection && ruleEngineDebug.makesCount > 0 {
                Text(String(format: t("detected_makes_count"), ruleEngineDebug.makesCount))
                    .font(.caption.bold())
                    .foregroundStyle(.green)
            }

            // During player tracking show live gain/loss count
            if detectionMode == .playerTracking
                && (possessionDebug.gainsTotal > 0 || possessionDebug.lossesTotal > 0) {
                Text(String(format: t("tracking_live_count"),
                            possessionDebug.gainsTotal, possessionDebug.lossesTotal))
                    .font(.caption.bold())
                    .foregroundStyle(.cyan)
            }
        }
    }

    // ── Phase 1 sections (unchanged logic) ──────────────────────────────────

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let url = videoURL {
                Label {
                    Text(url.lastPathComponent).lineLimit(1)
                } icon: {
                    Image(systemName: "film")
                }
            }

            // Three-state event status
            let makeCount  = events.filter { $0.type == "make" }.count
            let gainCount  = events.filter { $0.type == "gain" }.count
            let lossCount  = events.filter { $0.type == "loss" }.count
            let totalCount = makeCount + gainCount + lossCount
            Label {
                if videoURL == nil {
                    Text(t("please_select_video"))
                        .foregroundStyle(.secondary)
                } else if totalCount == 0 {
                    Text(t("no_events_hint"))
                        .foregroundStyle(.secondary)
                } else if droppedEventCount > 0 {
                    Text(String(format: t("events_with_dropped"), makeCount, droppedEventCount))
                        .foregroundStyle(.orange)
                } else {
                    let parts = [
                        makeCount > 0 ? String(format: t("events_count"), makeCount) : nil,
                        gainCount > 0 ? String(format: t("gains_count"), gainCount) : nil,
                        lossCount > 0 ? String(format: t("losses_count"), lossCount) : nil,
                    ].compactMap { $0 }
                    Text(parts.joined(separator: " · "))
                }
            } icon: {
                Image(systemName: "target")
                    .foregroundStyle(
                        videoURL == nil      ? Color.secondary
                        : totalCount == 0    ? Color.secondary
                        : droppedEventCount > 0 ? Color.orange : Color.green
                    )
            }

            if !clipRanges.isEmpty {
                let total = String(format: "%.1f",
                                   clipRanges.reduce(0) { $0 + $1.duration })
                Label {
                    Text(String(format: t("clips_summary"), clipRanges.count, total))
                } icon: {
                    Image(systemName: "scissors").foregroundStyle(.blue)
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private var eventListSection: some View {
        Button { showEventEditor = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "list.number")
                    .font(.title3)
                    .foregroundStyle(.orange)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t("event_list_title"))
                        .font(.callout.bold())
                        .foregroundStyle(.primary)
                    Text("\(events.count) \(t("events_label"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color(.systemGray6))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }

    private var rangeListSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: t("merged_clips"), count: clipRanges.count)

            ForEach(Array(clipRanges.enumerated()), id: \.element.id) { idx, range in
                RangeRow(range: range, index: idx + 1) {
                    previewRange(range)
                }
            }
        }
    }

    private var progressSection: some View {
        VStack(spacing: 8) {
            ProgressView(value: exporter.progress)
                .tint(.orange)
                .animation(.linear(duration: 0.1), value: exporter.progress)
            Text(String(format: t("exporting_progress"), exporter.progress * 100))
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(role: .destructive) {
                exporter.cancelExport()
            } label: {
                Label(t("cancel_export"), systemImage: "xmark.circle")
                    .font(.caption)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.1))
                    .foregroundColor(.red)
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
    }

    private func retrySection(message: String) -> some View {
        VStack(spacing: 10) {
            Label {
                Text(String(format: t("export_failed"), message))
                    .font(.callout)
                    .multilineTextAlignment(.center)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }

            Button(t("retry_export")) { startExport() }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color.red.opacity(0.06))
        .cornerRadius(12)
    }

    // MARK: - Multi-clip result sheet

    private var clipsResultSheet: some View {
        NavigationStack {
            List(Array(exporter.exportedURLs.enumerated()), id: \.offset) { idx, url in
                HStack {
                    Image(systemName: "video.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "Clip %03d", idx + 1))
                            .font(.callout.bold())
                        Text(url.lastPathComponent)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.body)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }
            }
            .navigationTitle(String(format: t("exported_clips_title"), exporter.exportedURLs.count))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(t("close")) { showClipsResult = false }
                }
                ToolbarItem(placement: .primaryAction) {
                    // "全部分享" — user can pick "存储到文件" from the share sheet
                    ShareLink(items: exporter.exportedURLs) {
                        Text(t("share_all"))
                    }
                }
            }
        }
    }

    private var presetSection: some View {
        VStack(spacing: 10) {
            // ── Export mode ──────────────────────────────────────────────────
            Picker(t("export_mode"), selection: $exportMode) {
                ForEach(ExportMode.allCases) { mode in
                    Text(mode.localizedName(using: langMgr)).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            // ── Clip-timing preset ───────────────────────────────────────────
            Picker(t("export_preset"), selection: $selectedPreset) {
                ForEach(ExportPreset.allCases) { preset in
                    Text(preset.localizedName(using: langMgr)).tag(preset)
                }
            }
            .pickerStyle(.segmented)

            // Parameter summary
            HStack {
                Text(selectedPreset.localizedSubtitle(using: langMgr))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(selectedPreset.localizedParamSummary(using: langMgr))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private var exportButton: some View {
        let isExportButtonEnabled = canExport && !exporter.isExporting && !isLoadingVideo
        return Button(action: startExport) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.up.fill")
                Text(exporter.isExporting ? t("exporting")
                     : exportMode == .highlight ? t("generate_highlight")
                     : String(format: t("export_clips_n"), rawRanges.count))
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(isExportButtonEnabled ? Color.orange : Color.gray.opacity(0.35))
            .foregroundColor(.white)
            .cornerRadius(14)
        }
        .disabled(!isExportButtonEnabled)
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Logic helpers
    // ═══════════════════════════════════════════════════════════════════════════

    private var canExport: Bool {
        guard videoURL != nil else { return false }
        return exportMode == .highlight ? !clipRanges.isEmpty : !rawRanges.isEmpty
    }

    // ── Video selection ─────────────────────────────────────────────────────

    private func handleSelection(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        isLoadingVideo    = true
        videoURL          = nil
        events            = []          // clear stale events from previous video
        clipRanges        = []
        rawRanges         = []
        droppedEventCount = 0
        previewTask?.cancel()
        stopDetection()
        currentFrameImage = nil
        currentDetections = []
        detectionStats    = t("switched_video_hint")
        ruleEngineDebug   = ShotRuleEngine.DebugState()
        // Reset player tracking state
        showPlayerSelectionSheet = false
        selectedPlayerPoint      = nil
        trackedPlayerBox      = nil
        trackedPlayerInitial  = nil
        possessionDebug       = PossessionRuleEngine.DebugState()
        detectionMode         = .shotDetection
        player?.pause()
        player = nil

        do {
            let vt = try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<VideoTransferable?, Error>) in
                item.loadTransferable(type: VideoTransferable.self) {
                    cont.resume(with: $0)
                }
            }
            isLoadingVideo = false
            if let vt {
                videoURL = vt.url
                player   = AVPlayer(url: vt.url)
                await recomputeClips()
            }
        } catch {
            isLoadingVideo = false
            alertMessage   = String(format: t("video_load_failed"), error.localizedDescription)
            showAlert      = true
        }
    }

    private func recomputeClips() async {
        guard let url = videoURL else {
            clipRanges = []; rawRanges = []; droppedEventCount = 0; return
        }
        let asset = AVURLAsset(url: url)
        let dur   = (try? await asset.load(.duration))
            .map { CMTimeGetSeconds($0) } ?? 3_600

        // Filter out events beyond the actual video duration before computing ranges
        let validEvents   = EventEngine.filterValid(events: events, videoDuration: dur)
        let totalMakes    = events.filter { $0.type == "make" }.count
        droppedEventCount = totalMakes - validEvents.count

        clipRanges = EventEngine.computeClipRanges(
            from:          validEvents,
            videoDuration: dur,
            pre:           preSeconds,
            post:          postSeconds,
            mergeGap:      mergeGapSeconds
        )
        rawRanges = EventEngine.computeRawClipRanges(
            from:          validEvents,
            videoDuration: dur,
            pre:           preSeconds,
            post:          postSeconds
        )
    }

    // ── Player seek / preview ───────────────────────────────────────────────

    private func seekPlayer(to seconds: Double) {
        guard let player else { return }
        currentFrameImage = nil
        currentDetections = []
        previewTask?.cancel()
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        )
        player.pause()
    }

    private func previewRange(_ range: ClipRange) {
        guard let player else { return }
        currentFrameImage = nil
        currentDetections = []
        previewTask?.cancel()
        player.seek(
            to: CMTime(seconds: range.start, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        )
        player.play()
        previewTask = Task {
            do {
                try await Task.sleep(for: .seconds(2))
                player.pause()
            } catch {
                // Cancelled
            }
        }
    }

    private func startExport() {
        guard let url = videoURL, !clipRanges.isEmpty else {
            alertMessage = t("export_no_clips")
            showAlert    = true
            return
        }
        switch exportMode {
        case .highlight:
            exporter.export(videoURL: url, clipRanges: clipRanges)   // merged
        case .clips:
            exporter.exportClips(inputURL: url, clips: rawRanges)    // one-per-event
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Detection Preview (Step 3 — 10 s)
    // ═══════════════════════════════════════════════════════════════════════════

    private func runDetectionPreview() {
        guard let url = videoURL else { return }

        player?.pause()
        isRunningDetection = true
        isFullDetection    = false
        detectionProgress  = 0
        detectionTimeLabel = ""
        currentDetections  = []
        currentFrameImage  = nil
        detectionStats     = ""
        detectionMaxSeconds = 10

        var totalBall = 0
        var totalHoop = 0
        var frameCount = 0

        detectionTask = Task {
            do {
                let engine  = try VisionInferenceEngine()
                let sampler = VideoFrameSampler()

                let maxSec: Double = 10
                for try await frame in sampler.frames(from: url, fps: 12, maxSeconds: maxSec) {
                    // Capture pixelBuffer on the current actor before entering Task.detached
                    let pb = frame.pixelBuffer
                    let detections = try await Task.detached {
                        try engine.detect(
                            pixelBuffer: pb,
                            timeSeconds: frame.timeSeconds
                        )
                    }.value

                    let uiImage = await Task.detached {
                        frame.toUIImage()
                    }.value

                    currentDetections  = detections
                    currentFrameImage  = uiImage
                    detectionTimeLabel = String(format: "%.2f s", frame.timeSeconds)
                    detectionProgress  = min(1.0, frame.timeSeconds / maxSec)

                    frameCount += 1
                    totalBall  += detections.filter { $0.label == "Basketball" }.count
                    totalHoop  += detections.filter { $0.label == "Basketball Hoop" }.count
                }

                detectionProgress = 1.0
                detectionStats = "\(frameCount) 帧  |  🏀 ball×\(totalBall)  🏟 hoop×\(totalHoop)"

            } catch is CancellationError {
                detectionStats = t("detection_cancelled")
            } catch {
                alertMessage = String(format: t("detection_failed"), error.localizedDescription)
                showAlert    = true
            }

            isRunningDetection = false
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Quick Detection (10 s from current player position, for tuning)
    // ═══════════════════════════════════════════════════════════════════════════

    private func runQuickDetection() {
        guard let url = videoURL else { return }

        let startSec = player?.currentTime().seconds ?? 0

        player?.pause()
        isRunningDetection = true
        isFullDetection    = true
        detectionProgress  = 0
        detectionTimeLabel = ""
        currentDetections  = []
        currentFrameImage  = nil
        detectionStats     = ""
        ruleEngineDebug    = ShotRuleEngine.DebugState()
        detectionMaxSeconds = 10

        detectionTask = Task {
            do {
                let detector = ShotDetector()

                let detectedEvents = try await detector.detectMakes(
                    videoURL:           url,
                    fps:                12,
                    startSeconds:       startSec,
                    maxDurationSeconds: 10
                ) { frac, debug, uiImage, dets in
                    detectionProgress  = frac
                    ruleEngineDebug    = debug
                    currentDetections  = dets
                    if let img = uiImage {
                        currentFrameImage  = img
                        detectionTimeLabel = String(format: "%.2f s", startSec + frac * 10)
                    }
                }

                detector.ruleEngine.flushDiagnostics()

                detectionProgress = 1.0
                let armed   = ruleEngineDebug.isArmed ? "armed" : "—"
                let reason  = ruleEngineDebug.lastTriggerReason
                detectionStats = "10s 快检（\(String(format: "%.1f", startSec))s 起）：\(detectedEvents.count) makes | \(armed) | \(reason)"

            } catch is CancellationError {
                detectionStats = t("detection_cancelled")
            } catch {
                alertMessage = String(format: t("detection_failed"), error.localizedDescription)
                showAlert    = true
            }

            isRunningDetection = false
            isFullDetection    = false
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Full Detection (Step 4 — entire video → events)
    // ═══════════════════════════════════════════════════════════════════════════

    private func runFullDetection() {
        guard let url = videoURL else { return }

        player?.pause()
        isRunningDetection = true
        isFullDetection    = true
        detectionProgress  = 0
        detectionTimeLabel = ""
        currentDetections  = []
        currentFrameImage  = nil
        detectionStats     = ""
        ruleEngineDebug    = ShotRuleEngine.DebugState()

        detectionTask = Task {
            do {
                // Pre-read duration for progress label
                let asset = AVURLAsset(url: url)
                let dur   = try await asset.load(.duration)
                let totalSec = CMTimeGetSeconds(dur)
                detectionMaxSeconds = totalSec

                let detector = ShotDetector()

                let detectedEvents = try await detector.detectMakes(
                    videoURL:           url,
                    fps:                12,
                    maxDurationSeconds: nil
                ) { frac, debug, uiImage, dets in
                    detectionProgress  = frac
                    ruleEngineDebug    = debug
                    currentDetections  = dets
                    if let img = uiImage {
                        currentFrameImage  = img
                        detectionTimeLabel = String(format: "%.2f s", frac * detectionMaxSeconds)
                    }
                }

                detector.ruleEngine.flushDiagnostics()

                // ── Detection complete: update events & ranges ──────────
                detectionProgress = 1.0
                detectionStats = String(format: t("detection_complete"), detectedEvents.count)

                if !detectedEvents.isEmpty {
                    events = detectedEvents
                    await recomputeClips()
                } else {
                    detectionStats = t("detection_no_makes")
                }

            } catch is CancellationError {
                detectionStats = t("detection_cancelled")
            } catch {
                alertMessage = String(format: t("detection_failed"), error.localizedDescription)
                showAlert    = true
            }

            isRunningDetection = false
            isFullDetection    = false
        }
    }

    // ── Shared stop ─────────────────────────────────────────────────────────

    private func stopDetection() {
        detectionTask?.cancel()
        detectionTask      = nil
        isRunningDetection = false
        isFullDetection    = false
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Player Tracking (select player → track → possession events)
    // ═══════════════════════════════════════════════════════════════════════════

    private func enterPlayerSelectionMode() {
        player?.pause()
        trackedPlayerInitial = nil
        trackedPlayerBox     = nil
        showPlayerSelectionSheet = true
    }

    private func runPlayerTracking() {
        guard let url = videoURL, trackedPlayerInitial != nil else { return }

        player?.pause()
        isRunningDetection = true
        isFullDetection    = true
        detectionProgress  = 0
        detectionTimeLabel = ""
        currentDetections  = []
        detectionStats     = ""
        possessionDebug    = PossessionRuleEngine.DebugState()
        ruleEngineDebug    = ShotRuleEngine.DebugState()

        detectionTask = Task {
            do {
                let asset = AVURLAsset(url: url)
                let dur   = try await asset.load(.duration)
                let totalSec = CMTimeGetSeconds(dur)
                detectionMaxSeconds = totalSec

                let detector = PlayerDetector()

                // Re-initialize the tracker on the detector's PlayerTracker
                // using the same point and time
                let currentSec = player?.currentTime().seconds ?? 0
                if let point = selectedPlayerPoint {
                    let _ = try await detector.initializePlayer(
                        videoURL: url,
                        tapPoint: point,
                        atSeconds: currentSec
                    )
                }

                let detectedEvents = try await detector.detectPossession(
                    videoURL:           url,
                    fps:                12,
                    maxDurationSeconds: nil,
                    detectShots:        true
                ) { frac, posDebug, shotDebug, uiImage, dets, tracked in
                    detectionProgress  = frac
                    possessionDebug    = posDebug
                    ruleEngineDebug    = shotDebug
                    currentDetections  = dets
                    trackedPlayerBox   = tracked?.boundingBox
                    if let img = uiImage {
                        currentFrameImage  = img
                        detectionTimeLabel = String(format: "%.2f s", frac * detectionMaxSeconds)
                    }
                }

                detectionProgress = 1.0

                let gains  = detectedEvents.filter { $0.type == "gain" }.count
                let losses = detectedEvents.filter { $0.type == "loss" }.count
                let makes  = detectedEvents.filter { $0.type == "make" }.count

                if !detectedEvents.isEmpty {
                    events = detectedEvents
                    await recomputeClips()
                    var parts: [String] = []
                    if gains + losses > 0 {
                        parts.append(String(format: t("tracking_complete"), gains, losses))
                    }
                    if makes > 0 {
                        parts.append(String(format: t("detection_complete"), makes))
                    }
                    detectionStats = parts.joined(separator: " | ")
                } else {
                    detectionStats = t("tracking_no_events")
                }

            } catch is CancellationError {
                detectionStats = t("detection_cancelled")
            } catch {
                alertMessage = String(format: t("detection_failed"), error.localizedDescription)
                showAlert    = true
            }

            isRunningDetection = false
            isFullDetection    = false
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Small helper views
// ═══════════════════════════════════════════════════════════════════════════════

private struct SectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.headline)
            Text("(\(count))").font(.subheadline).foregroundStyle(.secondary)
            Spacer()
        }
    }
}

private struct RangeRow: View {
    let range: ClipRange
    let index: Int
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Text("\(index)")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Color.blue)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "%.1f s  –  %.1f s",
                                range.start, range.end))
                        .monospacedDigit()
                        .font(.callout)
                    Text(String(format: "时长 %.1f s", range.duration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.blue)
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
            .background(Color(.systemGray6))
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject(LanguageManager())
}
