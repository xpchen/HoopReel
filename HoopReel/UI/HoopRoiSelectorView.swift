import SwiftUI

// MARK: - HoopRoiSelectorView

/// Transparent overlay placed over the video player.
/// User drag → draws a rect → committed to `selectionNormalized` (Vision coords,
/// bottom-left origin, 0–1). When `isActive` is false, the committed box is
/// rendered but touch events pass through to the player below.
struct HoopRoiSelectorView: View {

    /// Current selection in Vision coordinate space (bottom-left origin).
    @Binding var selectionNormalized: CGRect?

    /// true = capture drag gestures; false = display only (scrolling still works).
    var isActive: Bool = false

    @State private var dragStart:   CGPoint = .zero
    @State private var dragCurrent: CGPoint = .zero
    @State private var isDragging   = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // ── Committed selection ──────────────────────────────────────
                if let norm = selectionNormalized, !isDragging {
                    roiBox(
                        rect:  toScreen(norm, size: geo.size),
                        fill:  Color.yellow.opacity(0.10),
                        color: Color.yellow,
                        dash:  [6, 3]
                    )
                }
                // ── Live drag feedback ───────────────────────────────────────
                if isDragging {
                    roiBox(
                        rect:  makeRect(dragStart, dragCurrent),
                        fill:  Color.white.opacity(0.05),
                        color: Color.white,
                        dash:  [4, 2]
                    )
                }
            }
            .allowsHitTesting(isActive)       // pass-through when inactive
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { v in
                        if !isDragging {
                            dragStart = v.startLocation
                            isDragging = true
                        }
                        dragCurrent = v.location
                    }
                    .onEnded { v in
                        let px = makeRect(dragStart, v.location)
                        let norm = toVision(px, size: geo.size)
                        // Discard tiny accidental taps
                        if norm.width > 0.02 && norm.height > 0.02 {
                            selectionNormalized = norm
                        }
                        isDragging = false
                    }
            )
        }
    }

    // MARK: - Drawing

    @ViewBuilder
    private func roiBox(
        rect:  CGRect,
        fill:  Color,
        color: Color,
        dash:  [CGFloat]
    ) -> some View {
        ZStack {
            Rectangle().fill(fill)
            Rectangle()
                .strokeBorder(color,
                              style: StrokeStyle(lineWidth: 2, dash: dash))
        }
        .frame(width: max(1, rect.width), height: max(1, rect.height))
        .position(x: rect.midX, y: rect.midY)
    }

    // MARK: - Coordinate helpers

    /// Two arbitrary corners → normalized pixel rect (no negative size).
    private func makeRect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// Screen-pixel rect → Vision normalized (bottom-left origin, 0–1).
    ///
    /// SwiftUI y=0 is at the top; Vision y=0 is at the bottom.
    /// Flip: visionY = 1 − screenY − height
    private func toVision(_ px: CGRect, size: CGSize) -> CGRect {
        let sw = size.width,  sh = size.height
        return CGRect(
            x:      px.minX  / sw,
            y:      1 - (px.minY + px.height) / sh,
            width:  px.width / sw,
            height: px.height / sh
        )
    }

    /// Vision normalized → screen-pixel rect (top-left origin, for rendering).
    ///
    /// screenY = (1 − vision.maxY) × viewHeight
    private func toScreen(_ norm: CGRect, size: CGSize) -> CGRect {
        CGRect(
            x:      norm.minX         * size.width,
            y:      (1 - norm.maxY)   * size.height,
            width:  norm.width        * size.width,
            height: norm.height       * size.height
        )
    }
}

// MARK: - Preview

#Preview {
    @Previewable @State var roi: CGRect? = CGRect(x: 0.25, y: 0.35, width: 0.5, height: 0.3)
    ZStack {
        Color.black
        Text("← drag to select →").foregroundStyle(.gray)
        HoopRoiSelectorView(selectionNormalized: $roi, isActive: true)
    }
    .frame(height: 200)
    .clipShape(RoundedRectangle(cornerRadius: 12))
}
