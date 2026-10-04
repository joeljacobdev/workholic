import AppKit
import CoreGraphics
import Darwin
import WorkholicCore

struct MachineSample {
    var wallMs: Int64
    var uptimeMs: Int64
    var idleMs: Int64
    var onConsole: Bool
    var displayAwake: Bool
    var bundleId: String?
    var displayName: String
}

func uptimeMilliseconds() -> Int64 {
    var time = timespec()
    clock_gettime(clockid_t(8), &time)
    return Int64(time.tv_sec) * 1000 + Int64(time.tv_nsec) / 1_000_000
}

func bootIdentifier() -> String {
    var time = timeval()
    var size = MemoryLayout<timeval>.stride
    sysctlbyname("kern.boottime", &time, &size, nil, 0)
    return String(time.tv_sec)
}

func machineSample(now: Date = Date()) -> MachineSample {
    let anyType = CGEventType(rawValue: ~0) ?? .null
    let any = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyType)
    let scroll = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .scrollWheel)
    let idleSeconds = min(any, scroll)
    let session = CGSessionCopyCurrentDictionary() as NSDictionary?
    let app = NSWorkspace.shared.frontmostApplication
    let name = app?.localizedName ?? "Unknown"
    return MachineSample(
        wallMs: Int64(now.timeIntervalSince1970 * 1000),
        uptimeMs: uptimeMilliseconds(),
        idleMs: Int64(idleSeconds * 1000),
        onConsole: (session?["kCGSSessionOnConsoleKey"] as? Bool) ?? false,
        displayAwake: CGDisplayIsAsleep(CGMainDisplayID()) == 0,
        bundleId: app?.bundleIdentifier,
        displayName: name
    )
}
