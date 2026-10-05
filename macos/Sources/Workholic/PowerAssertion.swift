import Foundation
import IOKit.pwr_mgt

/// Keeps the display, and with it the Mac, from idling to sleep. Closing the lid still sleeps a laptop.
@MainActor
final class PowerAssertion {
    private var id: IOPMAssertionID = 0
    private var held = false

    func hold(reason: String) {
        guard !held else { return }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        held = result == kIOReturnSuccess
        if !held { NSLog("Workholic could not keep the Mac awake: \(result)") }
    }

    func release() {
        guard held else { return }
        IOPMAssertionRelease(id)
        held = false
    }
}
