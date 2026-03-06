import Foundation
import CoreGraphics

// MARK: - PossessionRuleEngine

/// Per-frame stateful rule engine that detects ball possession changes
/// for the tracked player.
///
/// State machine:
/// ```
/// noPossession ──(ball near player ≥ gainFramesRequired)──> targetHasBall  → emit "gain"
/// targetHasBall ──(ball far from player ≥ lossFramesRequired)──> noPossession → emit "loss"
/// ball undetected for ≥ missingBallMaxFrames → unknown (freeze, no events)
/// ```
///
/// Coordinate convention: **top-left normalized** (x→right, y→down, [0, 1]).
final class PossessionRuleEngine {

    // MARK: Tunable Parameters

    /// Normalized distance threshold: ball center to player box edge.
    /// Negative distance means ball is inside the box.
    var proximityThreshold: Float = 0.08

    /// Consecutive frames of proximity required to confirm ball gain.
    var gainFramesRequired: Int = 3

    /// Consecutive frames of separation required to confirm ball loss.
    var lossFramesRequired: Int = 4

    /// Minimum seconds between consecutive gain/loss events.
    var cooldownSeconds: Double = 1.0

    /// Frames without ball detection before entering "unknown" state.
    var missingBallMaxFrames: Int = 12

    // MARK: - Possession State

    enum PossessionState: String, Sendable {
        case noPossession
        case targetHasBall
        case unknown
    }

    // MARK: - Debug State

    struct DebugState: Sendable {
        var possessionState: String = PossessionState.noPossession.rawValue
        var trackedPlayerRect: CGRect? = nil
        var ballRect: CGRect? = nil
        var ballNearPlayer: Bool = false
        var proximityDistance: Float = 999
        var proximityCount: Int = 0
        var separationCount: Int = 0
        var gainsTotal: Int = 0
        var lossesTotal: Int = 0
        var lastEventReason: String = ""
    }

    private(set) var debugState = DebugState()

    // MARK: - Internal State

    private var state: PossessionState = .noPossession
    private var proximityCounter: Int = 0
    private var separationCounter: Int = 0
    private var missingBallCounter: Int = 0
    private var lastEventTime: Double = -.infinity
    private(set) var detectedEvents: [Event] = []

    // MARK: - Diagnostic Log

    private(set) var diagnosticLines: [String] = []

    private lazy var diagPath: URL? =
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("hoopreel_possession_diag.txt")

    private func log(_ s: String) {
        diagnosticLines.append(s)
        guard let p = diagPath, let d = (s + "\n").data(using: .utf8) else { return }
        if let fh = FileHandle(forWritingAtPath: p.path) {
            fh.seekToEndOfFile(); fh.write(d); fh.closeFile()
        } else { try? d.write(to: p) }
    }

    // MARK: - Public API

    /// Process one frame with player tracking + ball detection results.
    ///
    /// - Parameters:
    ///   - playerBox: Tracked player bounding box (top-left, normalized). Nil if player lost.
    ///   - ballBox:   Ball bounding box (top-left, normalized). Nil if ball not detected.
    ///   - timeSeconds: Current frame timestamp.
    /// - Returns: An Event if a gain/loss transition occurred, nil otherwise.
    @discardableResult
    func consumeFrame(
        playerBox: CGRect?,
        ballBox: CGRect?,
        timeSeconds: Double
    ) -> Event? {

        debugState.trackedPlayerRect = playerBox
        debugState.ballRect = ballBox
        debugState.possessionState = state.rawValue

        // Player lost — freeze state, don't emit events
        guard let player = playerBox else {
            log(String(format: "t=%.2f  PLAYER=nil  state=%@", timeSeconds, state.rawValue))
            return nil
        }

        // Ball not detected
        guard let ball = ballBox else {
            missingBallCounter += 1
            debugState.ballNearPlayer = false
            debugState.proximityDistance = 999

            // In targetHasBall: ball often occluded by the player during dribble.
            // Don't immediately transition. Only go unknown after many frames.
            if missingBallCounter >= missingBallMaxFrames && state != .unknown {
                let prevState = state
                state = .unknown
                log(String(format: "t=%.2f  BALL=nil×%d  state=%@→unknown",
                           timeSeconds, missingBallCounter, prevState.rawValue))
            } else {
                log(String(format: "t=%.2f  BALL=nil×%d  state=%@",
                           timeSeconds, missingBallCounter, state.rawValue))
            }

            debugState.possessionState = state.rawValue
            return nil
        }

        // Ball detected — reset missing counter
        missingBallCounter = 0

        // Compute distance from ball center to player box
        let dist = Self.ballPlayerDistance(ball: ball, player: player)
        let isNear = dist < proximityThreshold

        debugState.ballNearPlayer = isNear
        debugState.proximityDistance = dist

        let cdRemaining = max(0, cooldownSeconds - (timeSeconds - lastEventTime))

        log(String(format:
            "t=%.2f  ball=(%.3f,%.3f)  player=(%.3f,%.3f,%.3f×%.3f)  dist=%.4f  near=%@  state=%@  prox=%d  sep=%d  cd=%.1f",
            timeSeconds, ball.midX, ball.midY,
            player.minX, player.minY, player.width, player.height,
            dist, isNear ? "Y" : "N", state.rawValue,
            proximityCounter, separationCounter, cdRemaining))

        var emittedEvent: Event?

        switch state {
        case .noPossession, .unknown:
            if isNear {
                proximityCounter += 1
                separationCounter = 0
                if proximityCounter >= gainFramesRequired && cdRemaining <= 0 {
                    state = .targetHasBall
                    proximityCounter = 0
                    lastEventTime = timeSeconds
                    let event = Event(time: timeSeconds, type: "gain")
                    detectedEvents.append(event)
                    debugState.gainsTotal += 1
                    debugState.lastEventReason = String(format:
                        "GAIN dist=%.4f prox=%d", dist, gainFramesRequired)
                    log(String(format: ">>> GAIN @ t=%.2f  dist=%.4f", timeSeconds, dist))
                    emittedEvent = event
                }
            } else {
                proximityCounter = 0
                separationCounter = 0
            }

        case .targetHasBall:
            if !isNear {
                separationCounter += 1
                proximityCounter = 0
                if separationCounter >= lossFramesRequired && cdRemaining <= 0 {
                    state = .noPossession
                    separationCounter = 0
                    lastEventTime = timeSeconds
                    let event = Event(time: timeSeconds, type: "loss")
                    detectedEvents.append(event)
                    debugState.lossesTotal += 1
                    debugState.lastEventReason = String(format:
                        "LOSS dist=%.4f sep=%d", dist, lossFramesRequired)
                    log(String(format: ">>> LOSS @ t=%.2f  dist=%.4f", timeSeconds, dist))
                    emittedEvent = event
                }
            } else {
                separationCounter = 0
                proximityCounter = 0
            }
        }

        debugState.proximityCount = proximityCounter
        debugState.separationCount = separationCounter
        debugState.possessionState = state.rawValue

        return emittedEvent
    }

    func reset() {
        state              = .noPossession
        proximityCounter   = 0
        separationCounter  = 0
        missingBallCounter = 0
        lastEventTime      = -.infinity
        detectedEvents     = []
        debugState         = DebugState()
        diagnosticLines    = []
        if let p = diagPath { try? "".write(to: p, atomically: true, encoding: .utf8) }
    }

    func flushDiagnostics() {
        let text = diagnosticLines.joined(separator: "\n")
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? text.write(to: docs.appendingPathComponent("hoopreel_possession_diag.txt"),
                            atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Distance Calculation

    /// Distance from ball center to the nearest edge of the player box.
    /// Returns negative if the ball center is inside the (expanded) player box.
    /// The player box is expanded by half the ball size for tolerance.
    static func ballPlayerDistance(ball: CGRect, player: CGRect) -> Float {
        let ballCenter = CGPoint(x: ball.midX, y: ball.midY)

        // Expand player box by half-ball dimensions
        let expanded = player.insetBy(
            dx: -ball.width * 0.5,
            dy: -ball.height * 0.5
        )

        if expanded.contains(ballCenter) {
            return -1.0  // ball inside player box
        }

        // Distance to nearest edge
        let dx = max(expanded.minX - ballCenter.x, ballCenter.x - expanded.maxX, 0)
        let dy = max(expanded.minY - ballCenter.y, ballCenter.y - expanded.maxY, 0)
        return Float(hypot(dx, dy))
    }
}
