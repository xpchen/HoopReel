import Foundation
import CoreGraphics

// MARK: - ShotRuleEngine

/// Per-frame stateful rule engine that converts detection boxes into make events.
///
/// ## Why EMA-based hoop tracking?
///
/// A basketball video is typically recorded with a moving/panning camera. The hoop
/// position in the frame changes continuously.  Locking the hoop to the first 1.5 s
/// produces a stale reference that makes zone calculations fail whenever the camera
/// moves even slightly.
///
/// Instead we use an **exponential moving average (EMA)** that follows the hoop with
/// a configurable lag.  At α = 0.5 and 12 fps the smoothed hoop tracks the actual
/// hoop position with < 2-frame latency while suppressing per-frame noise.
///
/// ## Detection strategy: Arrival-based with candidate+confirm
///
/// The YOLO-nano model rarely detects the ball in flight near the rim (too fast,
/// too small).  Instead it reliably detects the ball when held by players.  We exploit
/// this by watching for the ball to **arrive** in the hoop zone after being observed
/// elsewhere:
///
/// 1. **Gap arrival (A)** — ball detected outside zone → undetected ≥2 frames → appears
///    inside zone (ball was in flight during the gap).
/// 2. **Displacement arrival (B)** — ball jumps by ≥ `arrivalDisplacement` between
///    consecutive frames while transitioning outside→inside.
/// 3. **IoU arrival (C)** — ball bbox overlaps hoop bbox on the transition frame.
/// 4. **Descent arrival (D)** — ball was above hoop recently and descended into the
///    zone, even if per-frame displacement is small.  Catches soft/arc shots.
/// 5. **Confirm** — A/B/C/D only set a *candidate*; make is emitted when confirmed by
///    IoU ≥ confirmIouThreshold, rim proximity, or ball disappearance in zone.
///
/// Ball selection: **score = confidence − 0.8 × distance(ballCenter, hoopCenter)**.
///
/// Coordinate convention: **top-left normalized** (x→right, y→down, [0, 1]).
final class ShotRuleEngine {

    // MARK: Tunable Parameters

    /// EMA smoothing factor for hoop position (0 = frozen, 1 = instantaneous).
    /// At 12 fps, 0.5 gives ~2-frame lag — fast enough to track hand-held panning.
    var hoopEmaAlpha: Double = 0.5

    /// If the detected hoop center jumps more than this (normalised) in a single frame,
    /// treat it as a scene cut and reset the EMA immediately.
    /// 0.30 avoids false resets from edge-of-frame artifacts (jump ≈ 0.20)
    /// while still catching real scene cuts (jump > 0.50).
    var hoopJumpResetThreshold: Double = 0.30

    /// IoU threshold: ball–hoop overlap to count as "ball at rim".
    var iouThreshold: Double = 0.08

    /// Hoop zone extends this many hoop-heights above hoop.minY.
    var hoopZoneAboveRatio: Double = 0.30

    /// Hoop zone extends this many hoop-heights below hoop.maxY.
    var hoopZoneBelowRatio: Double = 1.20

    /// Extra horizontal tolerance beyond half-hoop-width, as a fraction of hoop width.
    var xMarginRatio: Double = 0.20

    /// Maximum time (s) from last outside detection to inside arrival to count as a make.
    var shotWindowSeconds: Double = 8.0

    /// Minimum displacement (normalised) to count as arrival without a detection gap.
    var arrivalDisplacement: Double = 0.05

    /// Consecutive frames without ball to confirm disappearance (candidate confirm).
    var disappearFrames: Int = 3

    /// Minimum seconds between two makes to avoid double-counting.
    var cooldownSeconds: Double = 6.0

    /// Seconds after a hoop-reset (scene cut) during which no new candidates can form.
    /// Prevents false positives when the camera cuts to a new scene and the ball
    /// appears near a different hoop position.
    var hoopResetCooldown: Double = 2.5

    /// If ball was inside zone within this many seconds, treat new inside detection
    /// as a continuation (not a fresh arrival).  Prevents brief-miss re-triggers.
    var insideGracePeriod: Double = 0.5

    /// Seconds after candidate is set during which confirmation must occur.
    var confirmWindowSeconds: Double = 2.0

    /// IoU ball–hoop ≥ this confirms a pending candidate.
    var confirmIouThreshold: Double = 0.05

    /// Ball Y within this fraction of hoopH from rimY confirms a pending candidate.
    var confirmRimYRatio: Double = 1.5

    /// Maximum displacement (normalised) for a 1-frame gap to be credible.
    /// If gap ≤ 1 and displacement > this value, skip PatternA/B/C (likely a
    /// detection switch between two different objects, not real ball movement).
    /// PatternD (descent) is exempt — it has its own physics validation.
    var maxShortGapDisplacement: Double = 0.20

    /// Consecutive frames with ball detected **outside** the hoop zone after a
    /// candidate is set.  If this count reaches `candidateOutsideMax`, the
    /// candidate is invalidated (ball clearly left the area).
    var candidateOutsideMax: Int = 3

    // MARK: - Debug State

    struct DebugState: Sendable {
        var smoothedHoopRect:  CGRect?  = nil
        var rimY:              CGFloat? = nil
        var selectedBallRect:  CGRect?  = nil
        var selectedHoopRect:  CGRect?  = nil
        var isHoopLocked:      Bool     = false   // true once EMA is initialised
        var cooldownRemaining: Double   = 0
        var makesCount:        Int      = 0
        var isArmed:           Bool     = false
        var lastAboveAge:      Double   = 0       // repurposed: age of last outside detection
        var lastTriggerReason: String   = ""
    }

    private(set) var debugState = DebugState()

    // MARK: Internal State

    // --- EMA hoop tracking ---
    private var smoothedHoopRect: CGRect?

    // --- Arrival tracking ---
    private var lastOutsideTime:        Double?
    private var lastOutsidePos:         CGPoint?
    private var wasInsideLastFrame:     Bool = false
    private var gapFramesSinceOutside:  Int  = 0

    // --- Inside tracking (grace period) ---
    private var lastInsideTime:         Double?
    private var missingAfterInside:     Int  = 0

    // --- Candidate + confirm ---
    private var candidateTime:          Double?
    private var candidateReason:        String  = ""
    private var candidateExpire:        Double  = -.infinity
    private var candidateSeenInZone:    Bool    = false
    private var candidateMissing:       Int     = 0
    private var candidateOutside:       Int     = 0

    private var lastMakeTime:       Double = -.infinity
    private var lastHoopResetTime:  Double = -.infinity
    private var makes:              [Event] = []

    // --- PatternD: ball descent history ---
    /// Tracks recent (t, by, bx) for detecting a ball descending through the hoop.
    private var ballYHistory: [(t: Double, by: CGFloat, bx: CGFloat)] = []

    // MARK: - Diagnostic Log
    private(set) var diagnosticLines: [String] = []

    /// Lazy file path – created once per instance, cleared in reset().
    private lazy var diagPath: URL? =
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("hoopreel_diag.txt")

    /// Append `s` to the in-memory log AND flush it immediately to the log file.
    private func log(_ s: String) {
        diagnosticLines.append(s)
        guard let p = diagPath, let d = (s + "\n").data(using: .utf8) else { return }
        if let fh = FileHandle(forWritingAtPath: p.path) {
            fh.seekToEndOfFile(); fh.write(d); fh.closeFile()
        } else { try? d.write(to: p) }
    }

    // MARK: - Public API

    func reset() {
        smoothedHoopRect      = nil
        lastOutsideTime       = nil
        lastOutsidePos        = nil
        wasInsideLastFrame    = false
        gapFramesSinceOutside = 0
        lastInsideTime        = nil
        missingAfterInside    = 0
        candidateTime         = nil
        candidateReason       = ""
        candidateExpire       = -.infinity
        candidateSeenInZone   = false
        candidateMissing      = 0
        candidateOutside      = 0
        lastMakeTime          = -.infinity
        lastHoopResetTime     = -.infinity
        makes                 = []
        ballYHistory          = []
        debugState            = DebugState()
        diagnosticLines       = []
        // Truncate log file so each run starts fresh
        if let p = diagPath { try? "".write(to: p, atomically: true, encoding: .utf8) }
    }

    func flushDiagnostics() {
        let text = diagnosticLines.joined(separator: "\n")
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? text.write(to: docs.appendingPathComponent("hoopreel_diag.txt"),
                            atomically: true, encoding: .utf8)
        }
    }

    @discardableResult
    func consumeFrame(timeSeconds: Double, detections: [Detection]) -> Event? {

        // ── Expire pending candidate ───────────────────────────────────────────
        if candidateTime != nil && timeSeconds > candidateExpire {
            log(String(format:
                "DROP t=%.2f  reason=expired  cand=%@", timeSeconds, candidateReason))
            candidateTime = nil; candidateSeenInZone = false; candidateMissing = 0; candidateOutside = 0
        }

        // ── Hoop detection ────────────────────────────────────────────────────
        let hoopDet = detections
            .filter  { $0.label == "Basketball Hoop" }
            .max(by: { $0.confidence < $1.confidence })
        let rawHoopRect = hoopDet?.rectTopLeft

        // ── EMA hoop update ────────────────────────────────────────────────────
        if let hr = rawHoopRect {
            if let cur = smoothedHoopRect {
                let jump = hypot(hr.midX - cur.midX, hr.midY - cur.midY)
                if jump > hoopJumpResetThreshold {
                    // Scene cut / fast pan — reset EMA to new position immediately
                    smoothedHoopRect = hr
                    lastHoopResetTime = timeSeconds
                    // Invalidate any pending candidate — it belongs to the old scene
                    if candidateTime != nil {
                        log(String(format:
                            "t=%.2f  HOOP RESET invalidated cand=%@", timeSeconds, candidateReason))
                        candidateTime = nil; candidateSeenInZone = false; candidateMissing = 0; candidateOutside = 0
                    }
                    log(String(format:
                        "t=%.2f  *** HOOP RESET (jump=%.3f)", timeSeconds, jump))
                } else {
                    let a = hoopEmaAlpha
                    smoothedHoopRect = CGRect(
                        x:      cur.minX   * (1-a) + hr.minX   * a,
                        y:      cur.minY   * (1-a) + hr.minY   * a,
                        width:  cur.width  * (1-a) + hr.width  * a,
                        height: cur.height * (1-a) + hr.height * a
                    )
                }
            } else {
                smoothedHoopRect = hr   // first ever hoop detection
            }
        }

        debugState.smoothedHoopRect = smoothedHoopRect
        debugState.isHoopLocked     = smoothedHoopRect != nil
        debugState.selectedHoopRect = rawHoopRect

        guard let hoop = smoothedHoopRect else {
            debugState.cooldownRemaining =
                max(0, cooldownSeconds - (timeSeconds - lastMakeTime))
            // Count gap even before hoop is known
            gapFramesSinceOutside += 1
            wasInsideLastFrame = false
            return nil
        }

        // ── Ball detection: score = conf − 0.8 × dist(center, hoopCenter) ────
        let ballCandidates = detections.filter { $0.label == "Basketball" }
        let hoopCenter = CGPoint(x: hoop.midX, y: hoop.midY)
        let ballDet = ballCandidates.max(by: {
            let d0 = hypot($0.rectTopLeft.midX - hoopCenter.x,
                           $0.rectTopLeft.midY - hoopCenter.y)
            let d1 = hypot($1.rectTopLeft.midX - hoopCenter.x,
                           $1.rectTopLeft.midY - hoopCenter.y)
            return ($0.confidence - 0.8*d0) < ($1.confidence - 0.8*d1)
        })
        let ballRect = ballDet?.rectTopLeft
        debugState.selectedBallRect = ballRect

        let rimY = hoop.minY + 0.80 * hoop.height
        debugState.rimY = rimY

        // ── Cooldown ─────────────────────────────────────────────────────────
        let cdRemaining = max(0, cooldownSeconds - (timeSeconds - lastMakeTime))
        let resetCdRemaining = max(0, hoopResetCooldown - (timeSeconds - lastHoopResetTime))
        debugState.cooldownRemaining = cdRemaining

        // ── Hoop zone boundaries ──────────────────────────────────────────────
        let hoopH    = hoop.height
        let hoopW    = hoop.width
        let hoopMidX = hoop.midX
        let xMargin  = xMarginRatio * hoopW
        let zoneTop    = hoop.minY - hoopZoneAboveRatio * hoopH
        let zoneBottom = hoop.maxY + hoopZoneBelowRatio * hoopH

        // ── Per-frame summary (always written, visible during run) ────────────
        let bConf = ballDet.map { String(format: "%.2f", $0.confidence) } ?? "-"
        let bPos  = ballRect.map { String(format: "(%.3f,%.3f)", $0.midX, $0.midY) } ?? "(-,-)"
        let hConf = String(format: "%.2f", hoopDet?.confidence ?? 0)
        let candStr = candidateTime != nil ? String(format: "%.2f", candidateTime!) : "nil"
        log(String(format:
            "FRAME t=%.2f bN=%d bConf=%@ bPos=%@ hConf=%@ hMid=(%.3f,%.3f) gap=%d cand=%@ cd=%.1f",
            timeSeconds, ballCandidates.count, bConf, bPos,
            hConf, hoop.midX, hoop.midY,
            gapFramesSinceOutside, candStr, cdRemaining))

        if let ball = ballRect {
            let bx = ball.midX
            let by = ball.midY
            let horizontalFit = abs(bx - hoopMidX) <= hoopW * 0.5 + xMargin
            let iou = Self.computeIoU(ball, hoop)
            let inHoopZone = (horizontalFit && by >= zoneTop && by <= zoneBottom)
                          || iou > iouThreshold

            // ── Diagnostic (always written, trigger or not) ───────────────
            let diagBase = String(format:
                "t=%.2f  ball=(%.3f,%.3f)  hoopMid=(%.3f,%.3f)  iou=%.3f  zoneIN=%@  gap=%d",
                timeSeconds, bx, by, hoopMidX, hoop.midY, iou,
                inHoopZone ? "Y" : "N", gapFramesSinceOutside)

            // Ball detected — reset disappearance counter
            candidateMissing = 0

            // Track ball Y position for PatternD (descent detection)
            ballYHistory.append((t: timeSeconds, by: by, bx: bx))
            ballYHistory.removeAll { timeSeconds - $0.t > 2.0 }

            if inHoopZone {
                candidateOutside = 0   // ball back in zone — reset outside counter
                let recentlyInside = lastInsideTime.map { timeSeconds - $0 } ?? .infinity

                // ── Candidate confirm (IoU or rim proximity) ──────────────────
                if candidateTime != nil {
                    candidateSeenInZone = true
                    let cIou    = Self.computeIoU(ball, hoop)
                    let rimDist = abs(by - rimY)
                    let confirmByIou = cIou >= confirmIouThreshold
                    let confirmByRim = rimDist <= confirmRimYRatio * hoopH
                    if (confirmByIou || confirmByRim) && cdRemaining <= 0 {
                        let r = String(format: "%@ ← CONF(iou=%.3f rim=%.3f)",
                            candidateReason, cIou, rimDist)
                        log("MAKE t=\(timeSeconds)  \(r)  via=iou/rim")
                        candidateTime = nil; candidateSeenInZone = false; candidateOutside = 0
                        lastInsideTime = timeSeconds; missingAfterInside = 0
                        wasInsideLastFrame = true
                        return emitMake(at: timeSeconds, reason: r)
                    }
                }

                if !wasInsideLastFrame && recentlyInside > insideGracePeriod {
                    // ── Genuine arrival transition ────────────────────────────
                    if let outsideT = lastOutsideTime, let outsideP = lastOutsidePos {
                        let dt = timeSeconds - outsideT
                        let disp = hypot(bx - outsideP.x, by - outsideP.y)
                        let hadGap = gapFramesSinceOutside >= 1

                        if dt <= shotWindowSeconds && cdRemaining <= 0 && resetCdRemaining <= 0 {
                            var reason: String?

                            // Short-gap displacement cap: if only 0-1 frames of gap
                            // and the ball "jumped" more than maxShortGapDisplacement,
                            // this is likely a detection switch (different object picked
                            // as ball), not real ball movement.  Block A/B/C.
                            let shortGapOk = gapFramesSinceOutside > 1
                                          || disp <= maxShortGapDisplacement

                            if shortGapOk {
                                // PatternA: gap ≥ 2 frames AND disp ≥ threshold
                                if hadGap && disp >= arrivalDisplacement {
                                    reason = String(format:
                                        "PatternA: gap=%d disp=%.3f dt=%.2f",
                                        gapFramesSinceOutside, disp, dt)
                                } else if disp >= arrivalDisplacement {
                                    reason = String(format:
                                        "PatternB: disp=%.3f dt=%.2f", disp, dt)
                                } else if iou > iouThreshold {
                                    reason = String(format:
                                        "PatternC: IoU=%.3f dt=%.2f", iou, dt)
                                }
                            }

                            // PatternD: ball descended from above hoop into zone.
                            // Catches makes where the ball gradually drops through
                            // the hoop with minimal per-frame displacement.
                            if reason == nil && ballYHistory.count >= 3 {
                                let hoopMinY = hoop.minY
                                let aboveEntries = ballYHistory.filter {
                                    $0.by < hoopMinY
                                    && abs($0.bx - hoopMidX) <= hoopW * 1.5
                                    && timeSeconds - $0.t <= 1.5
                                }
                                // Ball just needs to be near the hoop top area
                                if let earliest = aboveEntries.first,
                                   by >= hoopMinY - 0.2 * hoopH {
                                    let yDrop = by - earliest.by
                                    if yDrop > 0.03 {
                                        reason = String(format:
                                            "PatternD: descent=%.3f from_t=%.2f",
                                            yDrop, earliest.t)
                                    }
                                }
                            }

                            let verdict = reason.map { "CANDIDATE(\($0))" }
                                ?? "SKIP(gap=\(gapFramesSinceOutside) disp=\(String(format:"%.3f",disp)))"
                            log("\(diagBase)  \(verdict)")

                            if let r = reason {
                                candidateTime       = timeSeconds
                                candidateReason     = r
                                candidateExpire     = timeSeconds + confirmWindowSeconds
                                candidateSeenInZone = true
                                candidateMissing    = 0
                                candidateOutside    = 0
                                log(String(format:
                                    "CAND t=%.2f  %@  expire=%.2f",
                                    timeSeconds, r, candidateExpire))
                            }
                        } else {
                            diagnosticLines.append("\(diagBase)  SKIP(dt=\(String(format:"%.2f",dt)) cd=\(String(format:"%.1f",cdRemaining)))")
                        }
                    } else {
                        diagnosticLines.append("\(diagBase)  SKIP(no-outside-ref)")
                    }
                } else {
                    diagnosticLines.append("\(diagBase)  CONT(wasIn=\(wasInsideLastFrame) recentIn=\(String(format:"%.2f",recentlyInside)))")
                }

                lastInsideTime     = timeSeconds
                missingAfterInside = 0
                wasInsideLastFrame = true

            } else {
                // Ball outside hoop zone

                // ── Below-hoop confirm: ball passed through net ─────────
                // If a candidate is pending and the ball was previously seen
                // in the hoop zone, a ball appearing well below the hoop
                // (and horizontally near it) confirms the make — the ball
                // fell through the net.
                if candidateTime != nil && candidateSeenInZone {
                    let belowHoop = by > hoop.maxY + 0.5 * hoopH
                    let nearHoopX = abs(bx - hoopMidX) <= hoopW
                    if belowHoop && nearHoopX && cdRemaining <= 0 {
                        let r = String(format:
                            "%@ ← CONF(below: y=%.3f hoopBot=%.3f)",
                            candidateReason, by, hoop.maxY)
                        log("MAKE t=\(timeSeconds)  \(r)  via=below-hoop")
                        candidateTime = nil; candidateSeenInZone = false; candidateMissing = 0; candidateOutside = 0
                        lastInsideTime = timeSeconds; missingAfterInside = 0
                        wasInsideLastFrame = false
                        return emitMake(at: timeSeconds, reason: r)
                    }
                }

                // ── Invalidate stale candidate if ball stays outside zone ──
                // If the ball is consistently tracked outside the hoop zone,
                // the candidate was likely spurious (e.g. marginal detection
                // near the hoop set a candidate, but the ball then moved away).
                if candidateTime != nil {
                    candidateOutside += 1
                    if candidateOutside >= candidateOutsideMax {
                        log(String(format:
                            "t=%.2f  CAND INVALIDATED (outside=%d) cand=%@",
                            timeSeconds, candidateOutside, candidateReason))
                        candidateTime = nil; candidateSeenInZone = false
                        candidateMissing = 0; candidateOutside = 0
                    }
                }

                lastOutsideTime       = timeSeconds
                lastOutsidePos        = CGPoint(x: bx, y: by)
                gapFramesSinceOutside = 0
                wasInsideLastFrame    = false
            }

        } else {
            // Ball not detected
            gapFramesSinceOutside += 1
            wasInsideLastFrame     = false
            ballYHistory.removeAll()

            diagnosticLines.append(String(format:
                "t=%.2f  BALL=nil  hoopMid=(%.3f,%.3f)  zoneIN=N  gap=%d  inAge=%.2f  cd=%.1f",
                timeSeconds, hoop.midX, hoop.midY, gapFramesSinceOutside,
                lastInsideTime.map { timeSeconds - $0 } ?? -1, cdRemaining))

            // ── Disappearance confirm for pending candidate ───────────────────
            if candidateTime != nil && candidateSeenInZone {
                candidateMissing += 1
                if candidateMissing >= disappearFrames && cdRemaining <= 0 {
                    let r = String(format: "%@ ← CONF(disappear=%d)",
                        candidateReason, candidateMissing)
                    log("MAKE t=\(timeSeconds)  \(r)  via=disappear")
                    candidateTime = nil; candidateSeenInZone = false; candidateMissing = 0; candidateOutside = 0
                    return emitMake(at: timeSeconds, reason: r)
                }
            }
        }

        debugState.isArmed      = lastOutsideTime != nil
        debugState.lastAboveAge = lastOutsideTime.map { timeSeconds - $0 } ?? 0

        return nil
    }

    var detectedMakes: [Event] { makes }

    // MARK: - Private

    private func emitMake(at timeSeconds: Double, reason: String) -> Event? {
        if let last = makes.last, abs(last.time - timeSeconds) < 1.0 {
            diagnosticLines.append(">>> DEDUP skip @ t=\(timeSeconds)  \(reason)")
            debugState.lastTriggerReason = "DEDUP: \(reason)"
            return nil
        }
        lastMakeTime          = timeSeconds
        lastOutsideTime       = nil
        lastOutsidePos        = nil
        wasInsideLastFrame    = false
        gapFramesSinceOutside = 0
        lastInsideTime        = nil
        missingAfterInside    = 0

        let event = Event(time: timeSeconds, type: "make")
        makes.append(event)
        debugState.makesCount        = makes.count
        debugState.lastTriggerReason = reason
        debugState.isArmed           = false
        log(">>> MAKE @ t=\(timeSeconds)  \(reason)")
        return event
    }

    static func computeIoU(_ a: CGRect, _ b: CGRect) -> Double {
        let inter = a.intersection(b)
        guard !inter.isNull && inter.width > 0 && inter.height > 0 else { return 0 }
        let i = Double(inter.width * inter.height)
        let u = Double(a.width * a.height + b.width * b.height) - i
        guard u > 0 else { return 0 }
        return i / u
    }
}
