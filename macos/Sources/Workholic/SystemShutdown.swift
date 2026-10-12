import AppKit
import Carbon

/// Asks macOS to shut down, as Apple's QA1134 describes: a "shut down" Apple Event to loginwindow.
/// It is the Apple menu's Shut Down without the dialog. Apps are asked to quit, so one with unsaved
/// work can still stop it. No admin rights are needed.
enum SystemShutdown {
    /// The Apple Event's send status. Zero means macOS took the request.
    static func request() -> OSStatus {
        var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kSystemProcess))
        let target = NSAppleEventDescriptor(
            descriptorType: typeProcessSerialNumber,
            bytes: &psn,
            length: MemoryLayout<ProcessSerialNumber>.size
        )
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEShutDown),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        guard let description = event.aeDesc else { return OSStatus(paramErr) }
        return AESendMessage(description, nil, AESendMode(kAENoReply), kAEDefaultTimeout)
    }
}
