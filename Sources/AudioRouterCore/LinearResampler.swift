import Foundation
@preconcurrency import AVFoundation

/// ストリーミング・サンプルレート変換器（src→dst、ブロック跨ぎ位相連続）。
/// IN エッジが任意レートの mono を AudioBus(48k) へ揃えるのに使う。
///
/// 中身は Apple の **AVAudioConverter** で、`Mastering` 品質のポリフェーズ
/// FIR を使う。旧 LinearResampler の線形補間は出力 Nyquist で 31% の
/// エイリアシング漏れがあって、44.1k マイク → shm 48k で「発話と同期した
/// ノイズ」を引き起こしていた (位相ボコーダーDSPがそれに反応)。本実装は
/// 等倍 (44.1→44.1 等) では near-bypass、非等倍では Apple 品質の補間。
///
/// 名前は LinearResampler のまま (呼び出し側の API 互換)。失敗時は無音を
/// 流すフォールバック挙動。
public final class LinearResampler: @unchecked Sendable {
    private let srcRate: Double
    private let dstRate: Double
    private let bypass: Bool
    private let converter: AVAudioConverter?
    private let srcFormat: AVAudioFormat?
    private let dstFormat: AVAudioFormat?
    private let outCapacity: AVAudioFrameCount = 8192
    private let outBuf: AVAudioPCMBuffer?

    public init(srcRate: Double, dstRate: Double) {
        self.srcRate = srcRate
        self.dstRate = dstRate > 0 ? dstRate : 48_000
        self.bypass = abs(self.srcRate - self.dstRate) < 0.001

        if bypass {
            self.srcFormat = nil
            self.dstFormat = nil
            self.converter = nil
            self.outBuf = nil
            return
        }

        let s = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                              sampleRate: self.srcRate, channels: 1, interleaved: false)
        let d = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                              sampleRate: self.dstRate, channels: 1, interleaved: false)
        let c = (s != nil && d != nil) ? AVAudioConverter(from: s!, to: d!) : nil
        if let c {
            // 高品質 SR 変換 (ポリフェーズ FIR 相当)。
            c.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            c.sampleRateConverterQuality   = .max
        }
        self.srcFormat = s
        self.dstFormat = d
        self.converter = c
        self.outBuf = (d != nil) ? AVAudioPCMBuffer(pcmFormat: d!, frameCapacity: outCapacity) : nil
    }

    /// 入力 mono を変換して出力 mono を closure へ。バッファは AVAudioPCMBuffer
    /// 内部メモリ → UnsafeBufferPointer。closure 終了後に再利用される。
    public func process(_ inb: UnsafeBufferPointer<Float>,
                        _ sink: (UnsafeBufferPointer<Float>) -> Void) {
        let n = inb.count
        guard n > 0 else { return }

        // 等倍はゼロコピー bypass。
        if bypass { sink(inb); return }

        guard let converter, let srcFormat, let outBuf else {
            // 変換器初期化失敗時は無音を出力長分流すと sink チェーンが破壊
            // されるため、何もしない (= ドロップ)。安定動作優先。
            return
        }

        // 入力 PCM バッファに inb をコピー。AVAudioPCMBuffer は frameLength を
        // セットしないと変換対象が空になるので注意。
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: srcFormat,
                                           frameCapacity: AVAudioFrameCount(n)) else { return }
        inBuf.frameLength = AVAudioFrameCount(n)
        if let dst = inBuf.floatChannelData?[0] {
            for i in 0..<n { dst[i] = inb[i] }
        }

        // 1 ブロック投入 → 出力をできるだけ取り出すループ。AVAudioConverter は
        // 内部にポリフェーズ FIR の delay state を保持するため、ブロック跨ぎで
        // クリック無しに繋がる。
        // (Swift 6 strict concurrency: 入力ブロックは @Sendable 扱いで、
        //  クロージャ内で mutate するフラグは class でラップして渡す。)
        final class Once: @unchecked Sendable { var fired = false }
        let once = Once()
        let block: AVAudioConverterInputBlock = { _, outStatus in
            if once.fired {
                outStatus.pointee = .noDataNow
                return nil
            }
            once.fired = true
            outStatus.pointee = .haveData
            return inBuf
        }

        // 出力バッファを使い回し。frameLength を毎回 0 にリセットしてから convert。
        while true {
            outBuf.frameLength = 0
            var err: NSError?
            let status = converter.convert(to: outBuf, error: &err, withInputFrom: block)
            let outN = Int(outBuf.frameLength)
            if outN > 0, let outp = outBuf.floatChannelData?[0] {
                sink(UnsafeBufferPointer(start: outp, count: outN))
            }
            if status == .endOfStream || status == .error || (once.fired && outN == 0) { break }
            if status == .inputRanDry { break }
            if outN == 0 { break }
        }
    }
}
