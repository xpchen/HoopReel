import SwiftUI

// MARK: - DetectionOverlayView

/// Renders bounding-box rectangles, labels, and optional debug state
/// on top of a video frame image.
///
/// Coordinate mapping:
///   1. Compute the aspect-fit display rect of the image within `viewSize`.
///   2. For each detection, flip the Vision y-axis (bottom-left → top-left)
///      and scale the normalized rect into the display rect.
///   3. Debug state rects are already in top-left coords — scale only.
struct DetectionOverlayView: View {

    let detections: [Detection]
    let imageSize:  CGSize          // natural pixel size of the source frame
    let viewSize:   CGSize          // GeometryReader size of the container

    /// Optional debug state from ShotRuleEngine. When non-nil the overlay
    /// draws lockedHoopRect, rimY line, and a status badge.
    var debugState: ShotRuleEngine.DebugState? = nil

    /// Optional tracked player box (top-left normalized).
    var trackedPlayerBox: CGRect? = nil

    /// Possession debug state for player tracking overlay.
    var possessionDebug: PossessionRuleEngine.DebugState? = nil

    var body: some View {
        Canvas { context, _ in
            let displayRect = aspectFitRect(
                imageSize: imageSize,
                in: viewSize
            )

            // ── 1. Detection boxes (Vision coords – flipped) ─────────────────
            for det in detections {
                let screenRect = mapVisionToScreen(det.rectNormalized, in: displayRect)
                let color: Color = det.label == "Basketball" ? .orange : .green

                context.stroke(
                    Path(screenRect),
                    with: .color(color),
                    lineWidth: 2
                )

                let text = "\(det.label)  \(Int(det.confidence * 100))%"
                let resolved = context.resolve(
                    Text(text)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                )
                let textSize = resolved.measure(in: viewSize)

                let bgRect = CGRect(
                    x:      screenRect.minX,
                    y:      max(0, screenRect.minY - textSize.height - 4),
                    width:  textSize.width + 8,
                    height: textSize.height + 4
                )
                context.fill(Path(bgRect), with: .color(color.opacity(0.85)))
                context.draw(
                    resolved,
                    at: CGPoint(x: bgRect.minX + 4, y: bgRect.minY + 2),
                    anchor: .topLeading
                )
            }

            // ── 2. Debug state (top-left coords – no flip) ──────────────────
            guard let debug = debugState else { return }

            // Smoothed hoop rect (green dashed)
            if let locked = debug.smoothedHoopRect {
                let screenRect = mapTopLeftToScreen(locked, in: displayRect)
                context.stroke(
                    Path(screenRect),
                    with: .color(.green.opacity(0.8)),
                    style: StrokeStyle(lineWidth: 2, dash: [6, 3])
                )
            }

            // rimY horizontal line (cyan dashed)
            if let rimY = debug.rimY {
                let screenY = displayRect.origin.y + rimY * displayRect.height
                var rimPath = Path()
                rimPath.move(to: CGPoint(x: displayRect.minX, y: screenY))
                rimPath.addLine(to: CGPoint(x: displayRect.maxX, y: screenY))
                context.stroke(
                    rimPath,
                    with: .color(.cyan),
                    style: StrokeStyle(lineWidth: 1.5, dash: [4, 2])
                )
            }

            // Status badge (bottom-right)
            var parts: [String] = []
            parts.append(debug.isHoopLocked ? "🔒Hoop" : "⏳Lock")
            if debug.cooldownRemaining > 0 {
                parts.append(String(format: "CD:%.1fs", debug.cooldownRemaining))
            }
            parts.append("makes:\(debug.makesCount)")
            let statusText = parts.joined(separator: " ")

            let resolved = context.resolve(
                Text(statusText)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
            )
            let textSize = resolved.measure(in: viewSize)
            let badgeRect = CGRect(
                x:      displayRect.maxX - textSize.width - 12,
                y:      displayRect.maxY - textSize.height - 8,
                width:  textSize.width + 8,
                height: textSize.height + 4
            )
            context.fill(Path(badgeRect), with: .color(.black.opacity(0.7)))
            context.draw(
                resolved,
                at: CGPoint(x: badgeRect.minX + 4, y: badgeRect.minY + 2),
                anchor: .topLeading
            )

            // ── 3. Tracked player box (top-left coords) ──────────────────
            if let playerBox = trackedPlayerBox {
                let pScreen = mapTopLeftToScreen(playerBox, in: displayRect)
                let pColor: Color = possessionDebug?.possessionState == "targetHasBall"
                    ? .green : .cyan

                context.stroke(
                    Path(pScreen),
                    with: .color(pColor),
                    style: StrokeStyle(lineWidth: 2.5, dash: [8, 4])
                )

                // Possession badge above player box
                if let pDebug = possessionDebug {
                    let label = pDebug.possessionState == "targetHasBall" ? "BALL" : "—"
                    let pResolved = context.resolve(
                        Text(label)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    )
                    let pTextSize = pResolved.measure(in: viewSize)
                    let pBadge = CGRect(
                        x:      pScreen.midX - pTextSize.width / 2 - 4,
                        y:      max(0, pScreen.minY - pTextSize.height - 6),
                        width:  pTextSize.width + 8,
                        height: pTextSize.height + 4
                    )
                    context.fill(Path(pBadge), with: .color(pColor.opacity(0.85)))
                    context.draw(
                        pResolved,
                        at: CGPoint(x: pBadge.minX + 4, y: pBadge.minY + 2),
                        anchor: .topLeading
                    )
                }
            }

            // ── 4. Possession stats badge (bottom-left) ──────────────────
            if let pDebug = possessionDebug,
               (pDebug.gainsTotal > 0 || pDebug.lossesTotal > 0) {
                let statsText = "G:\(pDebug.gainsTotal) L:\(pDebug.lossesTotal)"
                let sResolved = context.resolve(
                    Text(statsText)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                )
                let sSize = sResolved.measure(in: viewSize)
                let sBadge = CGRect(
                    x:      displayRect.minX + 4,
                    y:      displayRect.maxY - sSize.height - 8,
                    width:  sSize.width + 8,
                    height: sSize.height + 4
                )
                context.fill(Path(sBadge), with: .color(.black.opacity(0.7)))
                context.draw(
                    sResolved,
                    at: CGPoint(x: sBadge.minX + 4, y: sBadge.minY + 2),
                    anchor: .topLeading
                )
            }
        }
    }

    // MARK: - Coordinate math

    /// Computes the aspect-fit display rect of `imageSize` centred in `containerSize`.
    private func aspectFitRect(imageSize: CGSize, in containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }

        let imageAspect     = imageSize.width  / imageSize.height
        let containerAspect = containerSize.width / containerSize.height

        let displayW: CGFloat
        let displayH: CGFloat

        if imageAspect > containerAspect {
            displayW = containerSize.width
            displayH = containerSize.width / imageAspect
        } else {
            displayH = containerSize.height
            displayW = containerSize.height * imageAspect
        }

        return CGRect(
            x: (containerSize.width  - displayW) / 2,
            y: (containerSize.height - displayH) / 2,
            width:  displayW,
            height: displayH
        )
    }

    /// Maps a **Vision normalized rect** (bottom-left origin) to screen points.
    private func mapVisionToScreen(_ visionRect: CGRect, in displayRect: CGRect) -> CGRect {
        let flippedY = 1 - visionRect.origin.y - visionRect.size.height
        return CGRect(
            x:      displayRect.origin.x + visionRect.origin.x      * displayRect.width,
            y:      displayRect.origin.y + flippedY                  * displayRect.height,
            width:  visionRect.size.width  * displayRect.width,
            height: visionRect.size.height * displayRect.height
        )
    }

    /// Maps a **top-left normalized rect** (already flipped) to screen points.
    private func mapTopLeftToScreen(_ rect: CGRect, in displayRect: CGRect) -> CGRect {
        CGRect(
            x:      displayRect.origin.x + rect.origin.x * displayRect.width,
            y:      displayRect.origin.y + rect.origin.y * displayRect.height,
            width:  rect.width  * displayRect.width,
            height: rect.height * displayRect.height
        )
    }
}

// MARK: - Preview

#Preview {
    let sampleDetections = [
        Detection(label: "Basketball",      confidence: 0.92,
                  rectNormalized: CGRect(x: 0.4, y: 0.5, width: 0.06, height: 0.06),
                  timeSeconds: 1.0),
        Detection(label: "Basketball Hoop", confidence: 0.88,
                  rectNormalized: CGRect(x: 0.42, y: 0.7, width: 0.12, height: 0.10),
                  timeSeconds: 1.0),
    ]

    Color.black
        .frame(width: 390, height: 210)
        .overlay {
            DetectionOverlayView(
                detections: sampleDetections,
                imageSize:  CGSize(width: 1920, height: 1080),
                viewSize:   CGSize(width: 390, height: 210),
                debugState:  ShotRuleEngine.DebugState(
                    smoothedHoopRect: CGRect(x: 0.42, y: 0.2, width: 0.12, height: 0.10),
                    rimY: 0.255,
                    isHoopLocked: true,
                    makesCount: 3
                )
            )
        }
}
