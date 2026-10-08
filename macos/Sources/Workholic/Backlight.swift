import AppKit
import CoreGraphics

/// The display backlight, through DisplayServices: the private framework the brightness keys use.
/// A black cover alone still leaves the panel lit; turning the backlight down makes it truly dim.
/// It reaches built-in and Apple displays; other monitors are left alone and keep the black cover.
/// The level before dimming is kept in UserDefaults, so a crash mid-cover is undone on the next launch.
@MainActor
final class Backlight {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let savedKey = "backlightSaved"
    private static let dimLevel: Float = 0.06
    private static let steps = 12
    private static let stepSeconds = 0.04

    private let get: GetFn?
    private let set: SetFn?
    /// Display id to the level it had before dimming. Empty when nothing is dimmed.
    private var saved: [CGDirectDisplayID: Float]
    private var ramp: Timer?

    init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
        get = handle.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: GetFn.self) }
        set = handle.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: SetFn.self) }
        let stored = UserDefaults.standard.dictionary(forKey: Self.savedKey) as? [String: Float] ?? [:]
        saved = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in UInt32(key).map { ($0, value) } })
    }

    var isDimmed: Bool { !saved.isEmpty }

    /// Puts back whatever a previous run left dimmed.
    func restoreAfterCrash() {
        if isDimmed { restore(animated: false) }
    }

    /// Turns every display it can reach down to a glow. A display already darker stays as it is.
    func dim() {
        guard let get, !isDimmed else { return }
        var targets: [CGDirectDisplayID: (from: Float, to: Float)] = [:]
        for display in onlineDisplays() {
            var level: Float = -1
            guard get(display, &level) == 0, level >= 0 else { continue }
            saved[display] = level
            targets[display] = (level, min(level, Self.dimLevel))
        }
        persist()
        animate(targets)
    }

    func restore(animated: Bool = true) {
        guard isDimmed, let get else { return }
        var targets: [CGDirectDisplayID: (from: Float, to: Float)] = [:]
        for (display, level) in saved {
            var now: Float = level
            _ = get(display, &now)
            targets[display] = (now, level)
        }
        saved = [:]
        persist()
        if animated { animate(targets) } else { apply(targets, fraction: 1) }
    }

    private func animate(_ targets: [CGDirectDisplayID: (from: Float, to: Float)]) {
        ramp?.invalidate()
        let start = Date()
        let duration = Double(Self.steps) * Self.stepSeconds
        ramp = Timer.scheduledTimer(withTimeInterval: Self.stepSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let fraction = Float(min(1, Date().timeIntervalSince(start) / duration))
                self.apply(targets, fraction: fraction)
                if fraction >= 1 {
                    self.ramp?.invalidate()
                    self.ramp = nil
                }
            }
        }
    }

    private func apply(_ targets: [CGDirectDisplayID: (from: Float, to: Float)], fraction: Float) {
        guard let set else { return }
        for (display, range) in targets {
            _ = set(display, range.from + (range.to - range.from) * min(1, fraction))
        }
    }

    private func onlineDisplays() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    private func persist() {
        let stored = Dictionary(uniqueKeysWithValues: saved.map { (String($0.key), $0.value) })
        if stored.isEmpty { UserDefaults.standard.removeObject(forKey: Self.savedKey) }
        else { UserDefaults.standard.set(stored, forKey: Self.savedKey) }
    }
}
