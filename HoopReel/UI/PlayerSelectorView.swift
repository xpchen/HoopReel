import SwiftUI
import AVFoundation

// MARK: - PlayerSelectorView

/// Transparent overlay placed over the video frame during tracking.
/// Displays the tracked player box and possession state.
/// Player **selection** is now handled by `PlayerSelectionSheet`.
struct PlayerSelectorView: View {

    /// Current tracked player bounding box (top-left, normalized).
    var trackedPlayerBox: CGRect?

    /// Possession state: "targetHasBall", "noPossession", "unknown"
    var possessionState: String?

    @EnvironmentObject private var langMgr: LanguageManager
    private func t(_ key: String) -> String { langMgr.tr(key) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // ── Tracked player bounding box ─────────────────────────
                if let box = trackedPlayerBox {
                    let screenRect = mapToScreen(box, in: geo.size)

                    Rectangle()
                        .strokeBorder(
                            possessionColor,
                            style: StrokeStyle(lineWidth: 2.5, dash: [8, 4])
                        )
                        .frame(width: screenRect.width, height: screenRect.height)
                        .position(x: screenRect.midX, y: screenRect.midY)

                    // Possession badge
                    if let state = possessionState {
                        let label = state == "targetHasBall"
                            ? t("possession_has_ball")
                            : t("possession_no_ball")
                        Text(label)
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(possessionColor.opacity(0.85))
                            .foregroundStyle(.white)
                            .cornerRadius(4)
                            .position(
                                x: screenRect.midX,
                                y: max(16, screenRect.minY - 12)
                            )
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: - Helpers

    private var possessionColor: Color {
        guard let state = possessionState else { return .cyan }
        return state == "targetHasBall" ? .green : .cyan
    }

    private func mapToScreen(_ rect: CGRect, in size: CGSize) -> CGRect {
        CGRect(
            x:      rect.minX * size.width,
            y:      rect.minY * size.height,
            width:  rect.width * size.width,
            height: rect.height * size.height
        )
    }
}

// MARK: - PlayerSelectionSheet

/// Full-screen sheet for selecting a player to track.
/// Shows the video frame large, allows multiple taps to re-select,
/// and has a confirm button to lock in the selection.
struct PlayerSelectionSheet: View {

    let videoURL: URL
    let atSeconds: Double

    /// Called when the user confirms player selection.
    /// Returns the initialized TrackedPlayer and the normalized tap point.
    var onConfirm: (TrackedPlayer?, CGPoint?) -> Void

    @EnvironmentObject private var langMgr: LanguageManager
    private func t(_ key: String) -> String { langMgr.tr(key) }

    @Environment(\.dismiss) private var dismiss

    @State private var frameImage: UIImage?
    @State private var tapPoint: CGPoint?
    @State private var candidatePlayer: TrackedPlayer?
    @State private var isProcessing = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // ── Video frame with tap target ────────────────────────────
                if let image = frameImage {
                    ZStack {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .overlay {
                                GeometryReader { geo in
                                    // ── Candidate bounding box ─────────
                                    if let player = candidatePlayer {
                                        let box = player.boundingBox
                                        let screenRect = CGRect(
                                            x:      box.minX * geo.size.width,
                                            y:      box.minY * geo.size.height,
                                            width:  box.width * geo.size.width,
                                            height: box.height * geo.size.height
                                        )
                                        Rectangle()
                                            .strokeBorder(
                                                Color.cyan,
                                                style: StrokeStyle(lineWidth: 3, dash: [8, 4])
                                            )
                                            .frame(width: screenRect.width, height: screenRect.height)
                                            .position(x: screenRect.midX, y: screenRect.midY)
                                    }

                                    // ── Tap marker ─────────────────────
                                    if let point = tapPoint, candidatePlayer == nil {
                                        Circle()
                                            .fill(.cyan.opacity(0.6))
                                            .frame(width: 24, height: 24)
                                            .position(
                                                x: point.x * geo.size.width,
                                                y: point.y * geo.size.height
                                            )
                                    }

                                    // Tap gesture
                                    Color.clear
                                        .contentShape(Rectangle())
                                        .onTapGesture { location in
                                            guard !isProcessing else { return }
                                            let normalized = CGPoint(
                                                x: location.x / geo.size.width,
                                                y: location.y / geo.size.height
                                            )
                                            tapPoint = normalized
                                            trySelectPlayer(at: normalized)
                                        }
                                }
                            }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // ── Bottom bar ────────────────────────────────────────────
                VStack(spacing: 10) {
                    if isProcessing {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(t("loading"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if candidatePlayer != nil {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(t("player_selected"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Text(t("tap_to_reselect_hint"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if let err = errorMessage {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "hand.tap.fill")
                                .font(.title3)
                                .foregroundStyle(.cyan)
                            Text(t("tap_player_hint"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 16)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
            }
            .background(Color.black)
            .navigationTitle(t("select_player"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(t("cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(t("confirm_selection")) {
                        onConfirm(candidatePlayer, tapPoint)
                        dismiss()
                    }
                    .disabled(candidatePlayer == nil)
                }
            }
        }
        .onAppear { loadFrame() }
    }

    // MARK: - Private

    private func loadFrame() {
        isProcessing = true
        Task {
            let detector = PlayerDetector()
            let (_, img) = try await detector.initializePlayer(
                videoURL: videoURL,
                tapPoint: CGPoint(x: 0.5, y: 0.5), // dummy — we'll re-init on tap
                atSeconds: atSeconds
            )
            frameImage = img
            isProcessing = false
        }
    }

    private func trySelectPlayer(at point: CGPoint) {
        isProcessing = true
        errorMessage = nil
        candidatePlayer = nil

        Task {
            let detector = PlayerDetector()
            let (tracked, img) = try await detector.initializePlayer(
                videoURL: videoURL,
                tapPoint: point,
                atSeconds: atSeconds
            )

            if let img { frameImage = img }

            if let tracked {
                candidatePlayer = tracked
            } else {
                errorMessage = t("no_player_found")
            }
            isProcessing = false
        }
    }
}
