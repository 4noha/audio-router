import Foundation
import CoreAudio

/// 出力デバイス1件（モニタ TO 候補：スピーカー等）。
public struct OutputDevice: Identifiable, Hashable, Sendable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
}

/// 入力デバイス1件（mic FROM 候補：マイク等）。
public struct InputDevice: Identifiable, Hashable, Sendable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
}

/// 出力可能な CoreAudio デバイスを列挙する。
public enum AudioDeviceEnumerator {

    public static func outputs() -> [OutputDevice] {
        let devices = CA.array(CA.system, kAudioHardwarePropertyDevices, AudioObjectID.self)
        var result: [OutputDevice] = []
        for dev in devices {
            guard hasOutputStreams(dev) else { continue }
            let name = CA.string(dev, kAudioObjectPropertyName) ?? "device \(dev)"
            let uid = CA.string(dev, kAudioDevicePropertyDeviceUID) ?? ""
            // private な集約デバイス（自作タップ等）は除外
            if name.hasPrefix("AudioRouter-") { continue }
            result.append(OutputDevice(id: dev, uid: uid, name: name))
        }
        return result.sorted { $0.name < $1.name }
    }

    public static func defaultOutput() -> OutputDevice? {
        guard let dev = CA.value(CA.system, kAudioHardwarePropertyDefaultOutputDevice,
                                 AudioObjectID(0)) else { return nil }
        let name = CA.string(dev, kAudioObjectPropertyName) ?? "device \(dev)"
        let uid = CA.string(dev, kAudioDevicePropertyDeviceUID) ?? ""
        return OutputDevice(id: dev, uid: uid, name: name)
    }

    public static func inputs() -> [InputDevice] {
        let devices = CA.array(CA.system, kAudioHardwarePropertyDevices, AudioObjectID.self)
        var result: [InputDevice] = []
        for dev in devices {
            guard hasStreams(dev, kAudioObjectPropertyScopeInput) else { continue }
            let name = CA.string(dev, kAudioObjectPropertyName) ?? "device \(dev)"
            let uid = CA.string(dev, kAudioDevicePropertyDeviceUID) ?? ""
            if name.hasPrefix("AudioRouter-") { continue }
            result.append(InputDevice(id: dev, uid: uid, name: name))
        }
        return result.sorted { $0.name < $1.name }
    }

    public static func defaultInput() -> InputDevice? {
        guard let dev = CA.value(CA.system, kAudioHardwarePropertyDefaultInputDevice,
                                 AudioObjectID(0)) else { return nil }
        let name = CA.string(dev, kAudioObjectPropertyName) ?? "device \(dev)"
        let uid = CA.string(dev, kAudioDevicePropertyDeviceUID) ?? ""
        return InputDevice(id: dev, uid: uid, name: name)
    }

    private static func hasOutputStreams(_ device: AudioObjectID) -> Bool {
        hasStreams(device, kAudioObjectPropertyScopeOutput)
    }

    private static func hasStreams(_ device: AudioObjectID,
                                   _ scope: AudioObjectPropertyScope) -> Bool {
        var address = CA.addr(kAudioDevicePropertyStreams, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else {
            return false
        }
        return size > 0
    }
}
