import Foundation
import CoreAudio
import AppKit

/// 音声を出している実行中プロセス1件（FROM 候補）。
public struct AudioProcess: Identifiable, Hashable, Sendable {
    public let id: AudioObjectID          // CoreAudio process object id
    public let pid: pid_t
    public let bundleID: String
    public let name: String
    public let isRunningOutput: Bool
}

/// CoreAudio のプロセスオブジェクトを列挙する（macOS 14.4+）。
public enum ProcessEnumerator {

    /// 音声出力中のプロセスを列挙。`onlyOutput=false` で全プロセス。
    public static func list(onlyOutput: Bool = true) -> [AudioProcess] {
        let objects = CA.array(CA.system, kAudioHardwarePropertyProcessObjectList, AudioObjectID.self)
        var result: [AudioProcess] = []
        for obj in objects {
            let pid = CA.value(obj, kAudioProcessPropertyPID, pid_t(0)) ?? -1
            if pid <= 0 { continue }
            let isOut = (CA.value(obj, kAudioProcessPropertyIsRunningOutput, UInt32(0)) ?? 0) != 0
            if onlyOutput && !isOut { continue }
            let bundleID = CA.string(obj, kAudioProcessPropertyBundleID) ?? ""
            let name = displayName(pid: pid, bundleID: bundleID)
            result.append(AudioProcess(id: obj, pid: pid, bundleID: bundleID,
                                        name: name, isRunningOutput: isOut))
        }
        // 名前で安定ソート（同名は pid 順）
        return result.sorted { $0.name == $1.name ? $0.pid < $1.pid : $0.name < $1.name }
    }

    /// PID → CoreAudio プロセスオブジェクト ID へ変換。
    public static func processObject(for pid: pid_t) -> AudioObjectID? {
        var address = CA.addr(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var inPID = pid
        var outObj = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            CA.system, &address,
            UInt32(MemoryLayout<pid_t>.size), &inPID,
            &size, &outObj)
        return status == noErr ? outObj : nil
    }

    private static func displayName(pid: pid_t, bundleID: String) -> String {
        if let app = NSRunningApplication(processIdentifier: pid),
           let n = app.localizedName, !n.isEmpty {
            return n
        }
        if !bundleID.isEmpty { return bundleID }
        return "pid \(pid)"
    }
}
