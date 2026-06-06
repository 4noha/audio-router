import Foundation
import AVFoundation
import CoreAudio

/// 捕捉した mono Float32 を任意の出力デバイス（スピーカー等）へ再生するモニタ。
/// best-effort: 失敗してもタップ/UDP 本経路は止めない。
/// 元アプリはミュートしていないため、モニタは「別デバイスへ流したい」時のみ使う
/// （既定出力で聴くなら不要。二重再生になるので注意）。
public final class AudioMonitor: @unchecked Sendable {

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let deviceID: AudioObjectID
    private let sampleRate: Double

    // 単純リングバッファ（mono Float32）
    private let lock = NSLock()
    private var ring: [Float]
    private var writeIdx = 0
    private var readIdx = 0
    private var filled = 0

    // プロデューサ(SpeakerOutEdge.enqueue)は 26ms 周期で 1248 サンプル単位の
    // burst supply (babigoe の DSP ブロックが /babigoe.out3 へ吐かれるリズム)。
    // 一方デバイス render は連続 (sampleRate fps)。pre-buffer 無しで再生開始すると
    // burst 間隙で ring が 0 近くまで降下し、render が部分ゼロ埋め=クリックになる。
    // 蓄積するまで再生せず無音返しすることで起動時の cold buffer をマージン化。
    private var primed = false
    private let primeFrames: Int

    public init(deviceID: AudioObjectID, sampleRate: Double,
                capacitySeconds: Double = 0.5,
                primeMs: Double = 50) {
        self.deviceID = deviceID
        self.sampleRate = sampleRate
        self.ring = [Float](repeating: 0, count: max(1, Int(sampleRate * capacitySeconds)))
        self.primeFrames = max(1, Int(sampleRate * primeMs / 1000.0))
    }

    public func start() throws {
        // 出力 AU のデバイスを指定（best-effort）
        var dev = deviceID
        let outAU = engine.outputNode.audioUnit
        if let outAU {
            AudioUnitSetProperty(outAU,
                                 kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0,
                                 &dev, UInt32(MemoryLayout<AudioObjectID>.size))
        }

        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let node = AVAudioSourceNode(format: fmt) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let n = Int(frameCount)
            // pre-fill 未到達なら一律無音返し (readIdx を進めない)。十分蓄積した
            // 時点で primed=true にしてその後は通常再生。これでバースト供給と
            // 連続 render の位相差で起きる underrun (=クリック) を抑える。
            self.lock.lock()
            if !self.primed {
                if self.filled >= self.primeFrames {
                    self.primed = true
                } else {
                    self.lock.unlock()
                    for buffer in abl {
                        guard let ptr = buffer.mData?.bindMemory(to: Float.self, capacity: n) else { continue }
                        for i in 0..<n { ptr[i] = 0 }
                    }
                    return noErr
                }
            }
            let avail = min(self.filled, n)
            self.lock.unlock()
            for buffer in abl {
                guard let ptr = buffer.mData?.bindMemory(to: Float.self, capacity: n) else { continue }
                self.lock.lock()
                for i in 0..<n {
                    if i < avail {
                        ptr[i] = self.ring[self.readIdx]
                        self.readIdx = (self.readIdx + 1) % self.ring.count
                    } else {
                        ptr[i] = 0
                    }
                }
                self.filled -= avail
                self.lock.unlock()
            }
            return noErr
        }
        sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
        engine.prepare()
        try engine.start()
    }

    public func stop() {
        engine.stop()
        if let sourceNode { engine.detach(sourceNode) }
        sourceNode = nil
        lock.lock()
        primed = false  // 再 start 時にまた蓄積から
        filled = 0; readIdx = 0; writeIdx = 0
        lock.unlock()
    }

    public func enqueue(_ samples: UnsafeBufferPointer<Float>) {
        lock.lock(); defer { lock.unlock() }
        for s in samples {
            ring[writeIdx] = s
            writeIdx = (writeIdx + 1) % ring.count
            if filled < ring.count {
                filled += 1
            } else {
                readIdx = (readIdx + 1) % ring.count // 上書き：最古を捨てる
            }
        }
    }
}
