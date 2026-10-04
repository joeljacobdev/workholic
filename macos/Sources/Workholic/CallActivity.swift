import CoreAudio
import CoreMediaIO
import Foundation

/// True when another process has a microphone or a camera running.
///
/// That is the stand-in for "on a call". The check does not open either device,
/// so it does not ask for microphone or camera permission.
///
/// A device counts as a microphone only when it has input channels and no output
/// channels. On current macOS the microphone and the speakers are separate
/// devices, and `kAudioStreamPropertyIsActive` stays set on an idle mic, so
/// neither speaker playback nor that stream flag is a call.
/// Screen-capture devices are hidden for this process before the camera list
/// is read. A failed read counts as not in use, so a reminder can still appear.
func callInProgress() -> Bool {
    microphoneInUse() || cameraInUse()
}

private func microphoneInUse() -> Bool {
    for device in audioDeviceIDs() {
        let input = channelCount(device, scope: kAudioObjectPropertyScopeInput)
        let output = channelCount(device, scope: kAudioObjectPropertyScopeOutput)
        guard input > 0, output == 0 else { continue }
        if runningSomewhere(device) { return true }
    }
    return false
}

private func audioDeviceIDs() -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var devices = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return [] }
    return devices
}

private func channelCount(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
    let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
    return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
}

private func runningSomewhere(_ device: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var running: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running)
    return status == noErr && running != 0
}

private func cameraInUse() -> Bool {
    hideScreenCaptureDevices()
    for device in cameraDeviceIDs() where cameraRunningSomewhere(device) {
        return true
    }
    return false
}

/// Screen sharing and screen recording show up as cameras unless this process opts out.
private func hideScreenCaptureDevices() {
    var address = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
    )
    var allow: UInt32 = 0
    CMIOObjectSetPropertyData(
        CMIOObjectID(kCMIOObjectSystemObject),
        &address,
        0,
        nil,
        UInt32(MemoryLayout<UInt32>.size),
        &allow
    )
}

private func cameraDeviceIDs() -> [CMIODeviceID] {
    var address = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
    )
    var size: UInt32 = 0
    let system = CMIOObjectID(kCMIOObjectSystemObject)
    guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == 0, size > 0 else { return [] }
    let count = Int(size) / MemoryLayout<CMIODeviceID>.size
    var devices = [CMIODeviceID](repeating: 0, count: count)
    var used: UInt32 = 0
    guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &devices) == 0 else { return [] }
    return devices
}

private func cameraRunningSomewhere(_ device: CMIODeviceID) -> Bool {
    var address = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
    )
    var running: UInt32 = 0
    var used: UInt32 = 0
    let status = CMIOObjectGetPropertyData(
        device,
        &address,
        0,
        nil,
        UInt32(MemoryLayout<UInt32>.size),
        &used,
        &running
    )
    return status == 0 && running != 0
}
