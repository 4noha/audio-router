import Foundation
import CoreAudio
import AudioToolbox

/// プロセスタップ → private 集約デバイス → IOProc で対象アプリの出力音声を捕捉し、
/// モノラル Float32 にダウンミックスして UDP(PCMSender) と任意のモニタへ分配する。
/// macOS 14.4+ 専用。
@available(macOS 14.4, *)
public final class ProcessTapEngine: @unchecked Sendable {

    public enum EngineError: Error, CustomStringConvertible {
        case translateFailed
        case createTapFailed(OSStatus)
        case tapFormatUnavailable
        case createAggregateFailed(OSStatus)
        case ioProcFailed(OSStatus)
        case startFailed(OSStatus)

        public var description: String {
            switch self {
            case .translateFailed:            return "PID をプロセスオブジェクトへ変換できません"
            case .createTapFailed(let s):     return "AudioHardwareCreateProcessTap 失敗 (OSStatus \(s))。音声タップ許可を確認してください"
            case .tapFormatUnavailable:       return "タップのフォーマット取得に失敗"
            case .createAggregateFailed(let s): return "集約デバイス作成に失敗 (OSStatus \(s))"
            case .ioProcFailed(let s):        return "IOProc 作成に失敗 (OSStatus \(s))"
            case .startFailed(let s):         return "デバイス開始に失敗 (OSStatus \(s))"
            }
        }
    }

    private var tapID = AudioObjectID(0)
    private var aggregateID = AudioObjectID(0)
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "audio-router.ioproc", qos: .userInteractive)

    private var sender: PCMSender?
    private var monitor: AudioMonitor?
    private var sourceChannels = 2
    private var sampleRate: Double = 48_000

    public private(set) var isRunning = false

    public init() {}

    /// 捕捉開始。`processObject` は ProcessEnumerator.processObject(for:) の値。
    public func start(processObject: AudioObjectID,
                      sendHost: String, sendPort: UInt16,
                      monitorDevice: AudioObjectID?) throws {
        stop()

        // 1) タップ記述（モノミックスダウン・private・元アプリはミュートしない）
        let desc = CATapDescription(
            monoMixdownOfProcesses: [processObject])
        desc.name = "AudioRouter Tap"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted

        var tap = AudioObjectID(0)
        let ts = AudioHardwareCreateProcessTap(desc, &tap)
        guard ts == noErr, tap != 0 else { throw EngineError.createTapFailed(ts) }
        tapID = tap

        // 2) タップの UID と フォーマット
        guard let tapUID = CA.string(tapID, kAudioTapPropertyUID) else {
            cleanup(); throw EngineError.tapFormatUnavailable
        }
        if let asbd = CA.value(tapID, kAudioTapPropertyFormat,
                               AudioStreamBasicDescription()) {
            sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48_000
            sourceChannels = Int(max(asbd.mChannelsPerFrame, 1))
        }

        // 3) private 集約デバイス（タップのみを含む）
        let aggUID = "AudioRouter-Agg-\(UUID().uuidString)"
        let aggDict: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "AudioRouter-Aggregate",
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [[String: Any]](),
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapUID,
                    kAudioSubTapDriftCompensationKey as String: true
                ]
            ]
        ]
        var agg = AudioObjectID(0)
        let asx = AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &agg)
        guard asx == noErr, agg != 0 else {
            cleanup(); throw EngineError.createAggregateFailed(asx)
        }
        aggregateID = agg

        // 4) 出力先（UDP / モニタ）
        sender = PCMSender(host: sendHost, port: sendPort,
                           channels: 1, sampleRate: UInt32(sampleRate))
        if let monitorDevice {
            monitor = AudioMonitor(deviceID: monitorDevice, sampleRate: sampleRate)
            try? monitor?.start()
        }

        // 5) IOProc（入力 = タップ音声）
        var procID: AudioDeviceIOProcID?
        let cs = AudioDeviceCreateIOProcIDWithBlock(
            &procID, aggregateID, ioQueue
        ) { [weak self] _, inInputData, _, _, _ in
            self?.handleInput(inInputData)
        }
        guard cs == noErr, let procID else {
            cleanup(); throw EngineError.ioProcFailed(cs)
        }
        ioProcID = procID

        let st = AudioDeviceStart(aggregateID, procID)
        guard st == noErr else { cleanup(); throw EngineError.startFailed(st) }

        isRunning = true
    }

    public func stop() {
        if let ioProcID, aggregateID != 0 {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        monitor?.stop(); monitor = nil
        sender?.stop(); sender = nil
        cleanup()
        isRunning = false
    }

    private func cleanup() {
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
    }

    /// realtime IOProc: タップ音声を mono Float32 化して分配。
    private func handleInput(_ list: UnsafePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: list))
        guard abl.count > 0 else { return }

        // mono mixdown 指定なので通常 1 buffer / 1ch だが、安全に汎用化。
        let first = abl[0]
        guard let raw = first.mData else { return }
        let chans = Int(max(first.mNumberChannels, 1))
        let totalFloats = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        guard totalFloats > 0 else { return }
        let src = raw.bindMemory(to: Float.self, capacity: totalFloats)
        let frames = totalFloats / chans

        if chans == 1 {
            let buf = UnsafeBufferPointer(start: src, count: frames)
            sender?.send(buf)
            monitor?.enqueue(buf)
        } else {
            var mono = [Float](repeating: 0, count: frames)
            for f in 0..<frames {
                var acc: Float = 0
                for c in 0..<chans { acc += src[f * chans + c] }
                mono[f] = acc / Float(chans)
            }
            mono.withUnsafeBufferPointer { buf in
                sender?.send(buf)
                monitor?.enqueue(buf)
            }
        }
    }
}
