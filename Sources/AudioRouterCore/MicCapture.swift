import AVFoundation
import CoreAudio

/// 選択した入力デバイス(マイク)を AVAudioEngine で取り込み、mono Float32 と
/// そのサンプルレートをコールバックで渡す。audio-router がハブとして
/// babigoe へ供給する mic 経路に使う。
public final class MicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let deviceID: AudioObjectID
    private let onAudio: (UnsafeBufferPointer<Float>, Double) -> Void
    private var started = false

    public init(deviceID: AudioObjectID,
                onAudio: @escaping (UnsafeBufferPointer<Float>, Double) -> Void) {
        self.deviceID = deviceID
        self.onAudio = onAudio
    }

    public func start() throws {
        // 入力 AUHAL のデバイスを指定（AudioMonitor の出力指定と対称）。
        var dev = deviceID
        if let inAU = engine.inputNode.audioUnit {
            AudioUnitSetProperty(inAU,
                                 kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0,
                                 &dev, UInt32(MemoryLayout<AudioObjectID>.size))
        }
        let input = engine.inputNode
        let fmt = input.inputFormat(forBus: 0)         // ハード入力フォーマット
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) {
            [weak self] buf, _ in self?.handle(buf)
        }
        engine.prepare()
        try engine.start()
        started = true
    }

    private func handle(_ buf: AVAudioPCMBuffer) {
        guard let ch = buf.floatChannelData else { return }
        let frames = Int(buf.frameLength)
        guard frames > 0 else { return }
        let chans = Int(buf.format.channelCount)
        let sr = buf.format.sampleRate
        if chans == 1 {
            onAudio(UnsafeBufferPointer(start: ch[0], count: frames), sr)
        } else {
            var mono = [Float](repeating: 0, count: frames)
            for f in 0..<frames {
                var acc: Float = 0
                for c in 0..<chans { acc += ch[c][f] }
                mono[f] = acc / Float(chans)
            }
            mono.withUnsafeBufferPointer { onAudio($0, sr) }
        }
    }

    public func stop() {
        guard started else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        started = false
    }

    deinit { stop() }
}
