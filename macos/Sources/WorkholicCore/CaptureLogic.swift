import Foundation

public struct CaptureConfig: Sendable, Equatable {
    public var samplePeriodMs: Int64
    public var slackMs: Int64
    public var sealMs: Int64
    public var idleThresholdMs: Int64

    public init(samplePeriodMs: Int64 = 20_000, slackMs: Int64 = 5_000, sealMs: Int64 = 300_000, idleThresholdMs: Int64 = 120_000) {
        self.samplePeriodMs = samplePeriodMs
        self.slackMs = slackMs
        self.sealMs = sealMs
        self.idleThresholdMs = idleThresholdMs
    }
}

public struct OpenSlice: Sendable, Equatable {
    public var appKey: String
    public var startWallMs: Int64
    public var durationMs: Int64
    public var uptimeMs: Int64

    public init(appKey: String, startWallMs: Int64, durationMs: Int64, uptimeMs: Int64) {
        self.appKey = appKey
        self.startWallMs = startWallMs
        self.durationMs = durationMs
        self.uptimeMs = uptimeMs
    }

    public var endWallMs: Int64 { startWallMs + durationMs }
}

public struct SampleTick: Sendable, Equatable {
    public var wallMs: Int64
    public var uptimeMs: Int64
    public var attending: Bool
    public var appKey: String
    /// Sleep, wake, or a clock jump. The open slice must not grow across this sample.
    public var brokeContinuity: Bool

    public init(wallMs: Int64, uptimeMs: Int64, attending: Bool, appKey: String, brokeContinuity: Bool = false) {
        self.wallMs = wallMs
        self.uptimeMs = uptimeMs
        self.attending = attending
        self.appKey = appKey
        self.brokeContinuity = brokeContinuity
    }
}

public enum CaptureStep: Sendable, Equatable {
    case hold
    case start(appKey: String, wallMs: Int64, uptimeMs: Int64)
    /// Grow the open slice by uptime, not by the wall clock.
    case extend(addMs: Int64)
    case seal
    case sealAndStart(appKey: String, wallMs: Int64, uptimeMs: Int64)
    /// Extend up to the seal cap, close that slice, and open the next one at the cap.
    case fillSeal(fillMs: Int64, restartWallMs: Int64, restartUptimeMs: Int64, appKey: String)
}

public func captureStep(open: OpenSlice?, sample: SampleTick, config: CaptureConfig) -> CaptureStep {
    if let open {
        if sample.brokeContinuity || sample.uptimeMs < open.uptimeMs {
            return sample.attending
                ? .sealAndStart(appKey: sample.appKey, wallMs: sample.wallMs, uptimeMs: sample.uptimeMs)
                : .seal
        }
        let delta = sample.uptimeMs - open.uptimeMs
        let wallDelta = sample.wallMs - open.endWallMs
        let continues = sample.attending
            && sample.appKey == open.appKey
            && delta > 0
            && delta <= config.samplePeriodMs + config.slackMs
            && abs(wallDelta - delta) <= config.slackMs
        if !continues {
            return sample.attending
                ? .sealAndStart(appKey: sample.appKey, wallMs: sample.wallMs, uptimeMs: sample.uptimeMs)
                : .seal
        }
        let room = config.sealMs - open.durationMs
        if delta <= room {
            return .extend(addMs: delta)
        }
        if room <= 0 {
            return .sealAndStart(appKey: sample.appKey, wallMs: sample.wallMs, uptimeMs: sample.uptimeMs)
        }
        return .fillSeal(
            fillMs: room,
            restartWallMs: open.endWallMs + room,
            restartUptimeMs: open.uptimeMs + room,
            appKey: open.appKey
        )
    }
    if sample.attending && !sample.brokeContinuity {
        return .start(appKey: sample.appKey, wallMs: sample.wallMs, uptimeMs: sample.uptimeMs)
    }
    return .hold
}

public let deniedBundleIds: Set<String> = [
    "com.apple.loginwindow",
    "com.apple.ScreenSaver.Engine",
]

private let appKeyPattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9._-]{1,200}$")

public func sanitizedAppKey(_ bundleId: String?) -> String {
    guard let bundleId, !bundleId.isEmpty else { return "unattributed" }
    let range = NSRange(bundleId.startIndex..., in: bundleId)
    if appKeyPattern.firstMatch(in: bundleId, range: range) == nil { return "unattributed" }
    return bundleId
}

public struct GateSample: Sendable, Equatable {
    public var onConsole: Bool
    public var displayAwake: Bool
    public var idleMs: Int64
    public var bundleId: String?
    /// A break or the pause screen is over everything. Time behind it is not attention.
    public var covered: Bool

    public init(onConsole: Bool, displayAwake: Bool, idleMs: Int64, bundleId: String?, covered: Bool = false) {
        self.onConsole = onConsole
        self.displayAwake = displayAwake
        self.idleMs = idleMs
        self.bundleId = bundleId
        self.covered = covered
    }
}

public func attending(sample: GateSample, idleThresholdMs: Int64) -> Bool {
    guard sample.onConsole, sample.displayAwake, !sample.covered else { return false }
    guard sample.idleMs >= 0, sample.idleMs < idleThresholdMs else { return false }
    if let bundleId = sample.bundleId, deniedBundleIds.contains(bundleId) { return false }
    return true
}

public func clippedMs(start: Int64, end: Int64, dayStart: Int64, dayEnd: Int64) -> Int64 {
    let left = max(start, dayStart)
    let right = min(end, dayEnd)
    return max(0, right - left)
}
