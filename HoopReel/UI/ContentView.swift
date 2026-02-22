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

    // MARK: State – Hoop ROI (Step 6)

    @State private var isSelectingHoop:   Bool    = false  // drag overlay active
    @State private var userSelectionRect: CGRect? = nil    // raw drawn rect (Vision coords)
    @State private var lockedRoiRect:     CGRect? = nil    // expanded+clamped final ROI
    @State private var isLockingROI:      Bool    = false  // spinner while finding hoop

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
        // When user finishes drawing, lock the ROI by running a quick inference
        .onChange(of: userSelectionRect) { _, rect in
            if let rect { Task { await lockHoopROI(userROI: rect) } }
        }
        // ── Sheets / alerts ───────────────────────────────────────────────────
        .sheet(isPresented: $showShare) {
            if let url = exporter.exportedURL {
                ShareSheet(activityItems: [url])
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showEventEditor) {
            EventEditorView(
                events:     $events,
                clipRanges: $clipRanges,
                videoURL:   videoURL,
                onChanged:  { await recomputeClips() }
            )
        }
        .sheet(isPresented: $showClipsResult) {
            clipsResultSheet
        }
        .alert("提示", isPresented: $showAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(alertMessage)
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
            Text("自动生成投篮精彩集锦")
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
                Text(isLoadingVideo    ? "加载中…"
                     : videoURL == nil ? "选择比赛视频"
                                       : "重新选择视频")
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

            // ── Hoop selector overlay (yellow, drag-to-draw) ────────────────
            HoopRoiSelectorView(
                selectionNormalized: $userSelectionRect,
                isActive: isSelectingHoop
            )

            // ── Locked ROI border (indigo, always shown when set) ───────────
            if let roi = lockedRoiRect {
                roiDebugOverlay(roi)
            }

            // ── ROI lock spinner ────────────────────────────────────────────
            if isLockingROI {
                ProgressView()
                    .tint(.indigo)
                    .scaleEffect(1.4)
                    .padding(10)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
        }
        .frame(height: 210)
        .cornerRadius(12)
        .clipped()
    }

    /// Semi-transparent indigo border for the active ROI (debug aid).
    private func roiDebugOverlay(_ roi: CGRect) -> some View {
        GeometryReader { geo in
            let r = CGRect(
                x:      roi.minX            * geo.size.width,
                y:      (1 - roi.maxY)      * geo.size.height,
                width:  roi.width           * geo.size.width,
                height: roi.height          * geo.size.height
            )
            ZStack {
                Rectangle().fill(Color.indigo.opacity(0.07))
                Rectangle()
                    .strokeBorder(Color.indigo,
                                  style: StrokeStyle(lineWidth: 1.5, dash: [8, 3]))
            }
            .frame(width: max(1, r.width), height: max(1, r.height))
            .position(x: r.midX, y: r.midY)
        }
        .allowsHitTesting(false)
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
                            debugState: isFullDetection ? ruleEngineDebug : nil
                        )
                    }
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
                Text("预览")
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
            // Toggle row
            Toggle(isOn: $showDebugOverlay) {
                Label("Debug Overlay", systemImage: "rectangle.dashed")
                    .font(.callout)
            }
            .tint(.orange)

            // ── Hoop ROI row ─────────────────────────────────────────────────
            HStack(spacing: 10) {
                Button {
                    if isSelectingHoop {
                        isSelectingHoop   = false
                        userSelectionRect = nil
                    } else {
                        isSelectingHoop = true
                    }
                } label: {
                    Label(isSelectingHoop ? "取消框选" : "Select Hoop",
                          systemImage: isSelectingHoop ? "xmark.circle" : "scope")
                        .font(.callout.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(isSelectingHoop ? .gray : .indigo)
                .disabled(videoURL == nil || isRunningDetection)

                if lockedRoiRect != nil {
                    Button { resetHoopROI() } label: {
                        Label("Reset ROI", systemImage: "arrow.counterclockwise")
                            .font(.callout.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.gray)
                    .disabled(isRunningDetection)
                }
            }

            // ROI status hint
            if isSelectingHoop {
                Text("在视频画面上拖拽框选篮筐区域")
                    .font(.caption).foregroundStyle(.indigo)
            } else if isLockingROI {
                Label("正在锁定篮筐…", systemImage: "scope")
                    .font(.caption).foregroundStyle(.indigo)
            } else if let roi = lockedRoiRect {
                Label(String(format: "ROI  %.2f,%.2f  %.2f×%.2f",
                             roi.minX, roi.minY, roi.width, roi.height),
                      systemImage: "scope")
                    .font(.caption.monospacedDigit()).foregroundStyle(.indigo)
            }

            // Buttons row
            if isRunningDetection {
                // Stop button
                Button(role: .destructive) {
                    stopDetection()
                } label: {
                    Label("停止检测", systemImage: "stop.circle.fill")
                        .font(.callout.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                // Quick test buttons (10 s from current player position)
                HStack(spacing: 10) {
                    Button {
                        runDetectionPreview()
                    } label: {
                        Label("Preview (10s)", systemImage: "viewfinder.rectangular")
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
                        Label("Detect (10s)", systemImage: "sparkle.magnifyingglass")
                            .font(.callout.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.mint)
                    .disabled(videoURL == nil || exporter.isExporting)
                }

                // Full detection button
                Button {
                    runFullDetection()
                } label: {
                    Label("Auto Detect (Full)", systemImage: "sparkle.magnifyingglass")
                        .font(.callout.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(videoURL == nil || exporter.isExporting)
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

    private var detectionProgressSection: some View {
        VStack(spacing: 6) {
            ProgressView(value: detectionProgress)
                .tint(isFullDetection ? .green : .purple)
                .animation(.linear(duration: 0.08), value: detectionProgress)
            Text(String(format: "%@ %.1f / %.0f 秒",
                        isFullDetection ? "检测进球中" : "检测中",
                        detectionProgress * detectionMaxSeconds,
                        detectionMaxSeconds))
                .font(.caption)
                .foregroundStyle(.secondary)

            // During full detection show live makes count
            if isFullDetection && ruleEngineDebug.makesCount > 0 {
                Text("已检测到 \(ruleEngineDebug.makesCount) 个进球")
                    .font(.caption.bold())
                    .foregroundStyle(.green)
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
            let makeCount = events.filter { $0.type == "make" }.count
            Label {
                if videoURL == nil {
                    Text("请选择视频")
                        .foregroundStyle(.secondary)
                } else if makeCount == 0 {
                    Text("尚未生成事件：点击 Auto Detect 或导入 events.json")
                        .foregroundStyle(.secondary)
                } else if droppedEventCount > 0 {
                    Text("\(makeCount) 个进球事件 · 忽略超时：\(droppedEventCount)")
                        .foregroundStyle(.orange)
                } else {
                    Text("\(makeCount) 个进球事件")
                }
            } icon: {
                Image(systemName: "target")
                    .foregroundStyle(
                        videoURL == nil      ? Color.secondary
                        : makeCount == 0     ? Color.secondary
                        : droppedEventCount > 0 ? Color.orange : Color.green
                    )
            }

            if !clipRanges.isEmpty {
                let total = String(format: "%.1f",
                                   clipRanges.reduce(0) { $0 + $1.duration })
                Label {
                    Text("\(clipRanges.count) 个片段 · 合计约 \(total) 秒")
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
                    Text("事件列表")
                        .font(.callout.bold())
                        .foregroundStyle(.primary)
                    Text("\(events.count) 个进球 · 点击编辑 / 预览")
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
            SectionHeader(title: "合并片段", count: clipRanges.count)

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
            Text(String(format: "正在导出 %.0f%%", exporter.progress * 100))
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(role: .destructive) {
                exporter.cancelExport()
            } label: {
                Label("取消导出", systemImage: "xmark.circle")
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
                Text("导出失败：\(message)")
                    .font(.callout)
                    .multilineTextAlignment(.center)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }

            Button("重新导出") { startExport() }
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
            .navigationTitle("导出片段（\(exporter.exportedURLs.count) 个）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showClipsResult = false }
                }
                ToolbarItem(placement: .primaryAction) {
                    // "全部分享" — user can pick "存储到文件" from the share sheet
                    ShareLink(items: exporter.exportedURLs) {
                        Text("全部分享")
                    }
                }
            }
        }
    }

    private var presetSection: some View {
        VStack(spacing: 10) {
            // ── Export mode ──────────────────────────────────────────────────
            Picker("导出模式", selection: $exportMode) {
                ForEach(ExportMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            // ── Clip-timing preset ───────────────────────────────────────────
            Picker("导出预设", selection: $selectedPreset) {
                ForEach(ExportPreset.allCases) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .pickerStyle(.segmented)

            // Parameter summary
            HStack {
                Text(selectedPreset.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(selectedPreset.paramSummary)
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
                Text(exporter.isExporting ? "导出中…"
                     : exportMode == .highlight ? "生成精彩集锦"
                     : "导出 \(rawRanges.count) 段视频")
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
        detectionStats    = "已切换视频，请重新 Auto Detect"
        ruleEngineDebug   = ShotRuleEngine.DebugState()
        resetHoopROI()
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
            alertMessage   = "视频加载失败：\(error.localizedDescription)"
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
            alertMessage = "请先选择视频并确保有可用片段"
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
                detectionStats = "检测已取消"
            } catch {
                alertMessage = "检测失败：\(error.localizedDescription)"
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
                    maxDurationSeconds: 10,
                    roiRectNormalized:  lockedRoiRect
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
                detectionStats = "检测已取消"
            } catch {
                alertMessage = "检测失败：\(error.localizedDescription)"
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
                    maxDurationSeconds: nil,
                    roiRectNormalized:  lockedRoiRect   // nil → full-frame fallback
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
                detectionStats = "完成：检测到 \(detectedEvents.count) 个进球"

                if !detectedEvents.isEmpty {
                    events = detectedEvents
                    await recomputeClips()
                } else {
                    detectionStats = "完成：未检测到进球（尝试调整参数或视频）"
                }

            } catch is CancellationError {
                detectionStats = "检测已取消"
            } catch {
                alertMessage = "检测失败：\(error.localizedDescription)"
                showAlert    = true
            }

            isRunningDetection = false
            isFullDetection    = false
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Hoop ROI (Step 6)
    // ═══════════════════════════════════════════════════════════════════════════

    /// Samples ~1 s of video inside `userROI`, picks the best hoop detection,
    /// then sets `lockedRoiRect` = expand(hoopBbox, 2.2×).
    private func lockHoopROI(userROI: CGRect) async {
        guard let url = videoURL else { return }
        isLockingROI = true
        defer { isLockingROI = false }
        do {
            let engine  = try VisionInferenceEngine()
            let sampler = VideoFrameSampler()
            var allDets: [Detection] = []

            // 6 fps × 1 s = up to 6 frames; enough to find a stable hoop
            for try await frame in sampler.frames(from: url, fps: 6, maxSeconds: 1.0) {
                let pb = frame.pixelBuffer
                let dets = try await Task.detached {
                    try engine.detect(
                        pixelBuffer:       pb,
                        timeSeconds:       frame.timeSeconds,
                        roiRectNormalized: userROI
                    )
                }.value
                allDets.append(contentsOf: dets)
                try Task.checkCancellation()
            }

            lockedRoiRect = RoiMapper.deriveROI(from: allDets, userROI: userROI)
        } catch {
            // Fallback: no hoop found → just expand the drawn rect
            lockedRoiRect = RoiMapper.expandAndClamp(userROI, by: 2.2)
        }
        isSelectingHoop = false
    }

    private func resetHoopROI() {
        userSelectionRect = nil
        lockedRoiRect     = nil
        isSelectingHoop   = false
    }

    // ── Shared stop ─────────────────────────────────────────────────────────

    private func stopDetection() {
        detectionTask?.cancel()
        detectionTask      = nil
        isRunningDetection = false
        isFullDetection    = false
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
}
