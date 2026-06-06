import CoreAudio
import Foundation
var sz: UInt32 = 0
var addr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyProcessObjectList,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz)
let n = Int(sz) / MemoryLayout<AudioObjectID>.size
var arr = [AudioObjectID](repeating: 0, count: n)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &arr)
for obj in arr {
    var pid: pid_t = 0
    var ps: UInt32 = UInt32(MemoryLayout<pid_t>.size)
    var paddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(obj, &paddr, 0, nil, &ps, &pid)
    var bundleRef: Unmanaged<CFString>?
    var bs: UInt32 = UInt32(MemoryLayout<CFString?>.size)
    var baddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(obj, &baddr, 0, nil, &bs, &bundleRef)
    var isOut: UInt32 = 0
    var os: UInt32 = 4
    var oaddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(obj, &oaddr, 0, nil, &os, &isOut)
    let bid = bundleRef?.takeRetainedValue() as String? ?? ""
    print(String(format: "pid=%6d  isOut=%d  bundle=%@", pid, isOut, bid))
}
