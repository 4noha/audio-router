import Foundation

/// audio-router 内部の名前付きオーディオバス。mono Float32 48kHz 固定。
/// 単一プロデューサ（1 つの IN エッジが write）＋複数コンシューマ
/// （複数の OUT エッジが各自のカーソルで read）を想定。
/// 各 read カーソルは独立。古いデータは上書き（リップシンク用途・ロス許容）。
public final class AudioBus: @unchecked Sendable {
    public static let rate = 48_000

    private let cap: Int
    private var ring: [Float]
    private var writeIndex: Int64 = 0          // 累積書込フレーム（単調増加）
    private let lock = NSLock()

    /// 診断: 直近 write のピーク絶対値と累積フレーム。
    public private(set) var lastPeak: Float = 0
    public private(set) var totalWritten: Int64 = 0

    public init(seconds: Double = 1.0) {
        self.cap = max(AudioBus.rate / 10, Int(Double(AudioBus.rate) * seconds))
        self.ring = [Float](repeating: 0, count: cap)
    }

    /// プロデューサ（IN エッジ）が mono 48k サンプルを書き込む。
    public func write(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress, samples.count > 0 else { return }
        lock.lock()
        var pk: Float = 0
        for i in 0..<samples.count {
            let s = base[i]
            ring[Int((writeIndex &+ Int64(i)) % Int64(cap))] = s
            let a = s < 0 ? -s : s
            if a > pk { pk = a }
        }
        writeIndex &+= Int64(samples.count)
        totalWritten = writeIndex
        lastPeak = pk
        lock.unlock()
    }

    public func makeReader() -> Reader { Reader(bus: self) }

    fileprivate func snapshotWrite() -> Int64 {
        lock.lock(); defer { lock.unlock() }; return writeIndex
    }

    fileprivate func copyOut(from readIndex: Int64,
                             into dst: UnsafeMutableBufferPointer<Float>,
                             count: Int) {
        guard let d = dst.baseAddress else { return }
        lock.lock()
        for i in 0..<count {
            d[i] = ring[Int((readIndex &+ Int64(i)) % Int64(cap))]
        }
        lock.unlock()
    }

    /// コンシューマ（OUT エッジ）。独立した read カーソルを持つ。
    public final class Reader: @unchecked Sendable {
        private let bus: AudioBus
        private var readIndex: Int64
        public private(set) var totalRead: Int64 = 0

        fileprivate init(bus: AudioBus) {
            self.bus = bus
            self.readIndex = bus.snapshotWrite()   // 接続時点以降を読む
        }

        /// dst を埋め、実データのフレーム数を返す（不足は無音）。
        @discardableResult
        public func read(into dst: UnsafeMutableBufferPointer<Float>) -> Int {
            let n = dst.count
            guard n > 0, let d = dst.baseAddress else { return 0 }
            let w = bus.snapshotWrite()
            var avail = w - readIndex
            if avail < 0 { avail = 0 }
            let busCap = Int64(bus.cap)
            if avail > busCap { readIndex = w - busCap; avail = busCap }
            let take = Int(min(avail, Int64(n)))
            if take > 0 { bus.copyOut(from: readIndex, into: dst, count: take) }
            for i in take..<n { d[i] = 0 }
            readIndex &+= Int64(take)
            totalRead &+= Int64(take)
            return take
        }
    }
}
