import Foundation

/// ストリーミング線形リサンプラ（src→dst、ブロック跨ぎ位相連続）。
/// IN エッジが任意レートの mono を AudioBus(48k) へ揃えるのに使う。
/// 等倍時は 1 サンプル遅延の一貫経路（クリック回避）。
public final class LinearResampler: @unchecked Sendable {
    private let step: Double          // 入力進み量/出力サンプル
    private var pos: Double = 0
    private var prevLast: Float = 0
    private var out = [Float](repeating: 0, count: 4096)

    public init(srcRate: Double, dstRate: Double) {
        let s = (srcRate > 0 ? srcRate : dstRate) / (dstRate > 0 ? dstRate : 48_000)
        self.step = s
    }

    /// 入力 mono を変換し、出力 mono を closure へ渡す（再利用バッファ）。
    public func process(_ inb: UnsafeBufferPointer<Float>,
                        _ sink: (UnsafeBufferPointer<Float>) -> Void) {
        let n = inb.count
        guard n > 0 else { return }
        let est = Int(Double(n) / step) + 4
        if out.count < est { out = [Float](repeating: 0, count: est) }

        var p = pos
        var outN = 0
        while true {
            let i0 = Int(floor(p))
            let i1 = i0 + 1
            if i1 > n - 1 { break }
            let s0 = i0 < 0 ? prevLast : inb[i0]
            let s1 = i1 < 0 ? prevLast : inb[i1]
            let frac = Float(p - Double(i0))
            if outN >= out.count {
                out.append(contentsOf: repeatElement(0, count: out.count))
            }
            out[outN] = s0 + (s1 - s0) * frac
            outN += 1
            p += step
        }
        pos = p - Double(n)
        prevLast = inb[n - 1]
        if outN > 0 {
            out.withUnsafeBufferPointer { full in
                sink(UnsafeBufferPointer(start: full.baseAddress, count: outN))
            }
        }
    }
}
