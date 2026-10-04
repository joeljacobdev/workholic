import WorkholicCore
import XCTest

final class CaptureLogicTests: XCTestCase {
    private let config = CaptureConfig()

    func testGapDoesNotBackfill() {
        let open = OpenSlice(appKey: "com.apple.Terminal", startWallMs: 1_000, durationMs: 20_000, uptimeMs: 20_000)
        let step = captureStep(
            open: open,
            sample: SampleTick(wallMs: 1_000 + 80_000, uptimeMs: 100_000, attending: true, appKey: "com.apple.Terminal"),
            config: config
        )
        XCTAssertEqual(step, .sealAndStart(appKey: "com.apple.Terminal", wallMs: 81_000, uptimeMs: 100_000))
    }

    func testUptimeDeltaExtendsAndWallSlackDoesNotInventTime() {
        let open = OpenSlice(appKey: "Mail", startWallMs: 0, durationMs: 0, uptimeMs: 1_000)
        let step = captureStep(
            open: open,
            sample: SampleTick(wallMs: 24_000, uptimeMs: 21_000, attending: true, appKey: "Mail"),
            config: config
        )
        XCTAssertEqual(step, .extend(addMs: 20_000))
    }

    func testSleepDoesNotExtendTheOpenSlice() {
        let open = OpenSlice(appKey: "Mail", startWallMs: 0, durationMs: 40_000, uptimeMs: 40_000)
        let step = captureStep(
            open: open,
            sample: SampleTick(wallMs: 90_000, uptimeMs: 40_500, attending: true, appKey: "Mail", brokeContinuity: true),
            config: config
        )
        XCTAssertEqual(step, .sealAndStart(appKey: "Mail", wallMs: 90_000, uptimeMs: 40_500))
    }

    func testIdleSealsWithoutStarting() {
        let open = OpenSlice(appKey: "Mail", startWallMs: 0, durationMs: 20_000, uptimeMs: 20_000)
        let step = captureStep(
            open: open,
            sample: SampleTick(wallMs: 40_000, uptimeMs: 40_000, attending: false, appKey: "Mail"),
            config: config
        )
        XCTAssertEqual(step, .seal)
    }

    func testSealCapStartsTheNextSlice() {
        let open = OpenSlice(appKey: "Mail", startWallMs: 0, durationMs: 290_000, uptimeMs: 290_000)
        let step = captureStep(
            open: open,
            sample: SampleTick(wallMs: 310_000, uptimeMs: 310_000, attending: true, appKey: "Mail"),
            config: config
        )
        XCTAssertEqual(
            step,
            .fillSeal(fillMs: 10_000, restartWallMs: 300_000, restartUptimeMs: 300_000, appKey: "Mail")
        )
    }

    func testAppChangeSealsAndStarts() {
        let open = OpenSlice(appKey: "Mail", startWallMs: 0, durationMs: 20_000, uptimeMs: 20_000)
        let step = captureStep(
            open: open,
            sample: SampleTick(wallMs: 40_000, uptimeMs: 40_000, attending: true, appKey: "Safari"),
            config: config
        )
        XCTAssertEqual(step, .sealAndStart(appKey: "Safari", wallMs: 40_000, uptimeMs: 40_000))
    }

    func testLockScreenIsNotAttention() {
        XCTAssertFalse(
            attending(
                sample: GateSample(onConsole: true, displayAwake: true, idleMs: 0, bundleId: "com.apple.loginwindow"),
                idleThresholdMs: 120_000
            )
        )
    }

    func testIdlePastTheThresholdIsNotAttention() {
        XCTAssertFalse(
            attending(
                sample: GateSample(onConsole: true, displayAwake: true, idleMs: 120_000, bundleId: "com.apple.Terminal"),
                idleThresholdMs: 120_000
            )
        )
    }

    func testAsleepDisplayIsNotAttention() {
        XCTAssertFalse(
            attending(
                sample: GateSample(onConsole: true, displayAwake: false, idleMs: 10, bundleId: "com.apple.Terminal"),
                idleThresholdMs: 120_000
            )
        )
    }

    func testOddBundleIdBecomesUnattributed() {
        XCTAssertEqual(sanitizedAppKey("has space"), "unattributed")
        XCTAssertEqual(sanitizedAppKey("com.apple.Terminal"), "com.apple.Terminal")
    }
}
