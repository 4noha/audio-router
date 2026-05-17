import Darwin
import Dispatch

/// 捕捉した mono Float32 を 4ksplitter へ POSIX 共有メモリ(ARPS v1)で渡す。
/// audio-router の「多経路」の 1 つ（UDP/モニタと並列に使う）。IP/ポート不使用、
/// ブロック毎の syscall も無し（接続後は共有領域へ直接書込）。再送なし・ロス許容。
///
/// メモリ契約 "ARPS v1"（C# 側 Arp1ShmWriter / VoiceShmReceiver と byte 一致）:
///   shm 名 "/4ksp.voice" / ヘッダ64B [0 u32 magic 0x53505241("ARPS"LE) /4 ver1
///   /8 u32 sampleRate(=48000固定) /12 ch1 /16 u32 capacity(=96000) /20 u32 ready
///   /32 i64 writeIndex /40 i64 readIndex] + Float32[capacity] リング。
///   受信側 4ksplitter が所有・初期化・破棄。本 writer は attach のみ（O_CREAT
///   しない）、不健全時は 1s ゲートで再接続。
public final class ShmSender: @unchecked Sendable {
    public static let nameToSplitter = "/4ksp.voice"   // 4ksplitter 受信
    public static let nameBabigoeIn  = "/babigoe.in"   // babigoe へ mic 供給
    private let name: String
    private static let magic: Int32 = 0x5350_5241   // "ARPS" LE
    private static let version: Int32 = 1
    private static let capacity = 96_000            // frames (2s @ 48k)
    private static let headerBytes = 64
    private static let totalBytes = headerBytes + capacity * 4
    private static let outRate: Double = 48_000

    // ヘッダオフセット
    private static let offMagic = 0, offVersion = 4, offRate = 8,
                       offChannels = 12, offCapacity = 16, offReady = 20,
                       offWrite = 32, offRead = 40

    // shm_open は C 可変長引数のため Swift から直接呼べない。
    // O_CREAT を使わない attach 専用なので可変長部は空 → 固定引数の
    // C 関数ポインタとして dlsym で解決して呼ぶ（ABI 安全）。
    private typealias ShmOpenFn = @convention(c) (UnsafePointer<CChar>, Int32) -> Int32
    private static let shmOpen: ShmOpenFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "shm_open")
        else { return nil }                       // -2 = RTLD_DEFAULT (macOS)
        return unsafeBitCast(sym, to: ShmOpenFn.self)
    }()
    private nonisolated(unsafe) static let mapFailed =
        UnsafeMutableRawPointer(bitPattern: -1)

    private var base: UnsafeMutableRawPointer?
    private var fd: Int32 = -1
    private var lastTryNs: UInt64 = 0
    private var connected = false

    // ストリーミング線形リサンプラ状態（srcRate→48k, ブロック跨ぎ連続）
    private let srcRate: Double
    private let step: Double
    private var pos: Double = 0
    private var prevLast: Float = 0
    private var out = [Float](repeating: 0, count: 4096)

    public init(srcSampleRate: Double, name: String = ShmSender.nameToSplitter) {
        self.name = name.isEmpty ? Self.nameToSplitter : name
        self.srcRate = srcSampleRate > 0 ? srcSampleRate : Self.outRate
        self.step = self.srcRate / Self.outRate
    }

    public func stop() {
        detach()
    }

    deinit { detach() }

    /// mono Float32(srcRate) サンプル列を 48k へ変換し共有リングへ書込。
    public func send(_ samples: UnsafeBufferPointer<Float>) {
        guard samples.count > 0 else { return }
        guard ensureConnected(), let base = base else { return }

        let n = samples.count
        let outN = resample(samples, n)
        if outN <= 0 { return }

        let cap = Self.capacity
        let w = loadI64(base, Self.offWrite)
        let start = Int(w % Int64(cap))
        let ring = base.advanced(by: Self.headerBytes)

        out.withUnsafeBytes { raw in
            let src = raw.baseAddress!
            if start + outN <= cap {
                ring.advanced(by: start * 4)
                    .copyMemory(from: src, byteCount: outN * 4)
            } else {
                let first = cap - start
                ring.advanced(by: start * 4)
                    .copyMemory(from: src, byteCount: first * 4)
                ring.copyMemory(from: src.advanced(by: first * 4),
                                byteCount: (outN - first) * 4)
            }
        }
        OSMemoryBarrier()
        storeI64(base, Self.offWrite, w + Int64(outN))
        OSMemoryBarrier()
    }

    // [prevLast, samples...] を仮想入力列とみなし線形補間で 48k 化。
    private func resample(_ inb: UnsafeBufferPointer<Float>, _ n: Int) -> Int {
        let est = Int(Double(n) / step) + 4
        if out.count < est { out = [Float](repeating: 0, count: est) }

        var p = pos
        var outN = 0
        while true {
            let i0 = Int(floor(p))
            let i1 = i0 + 1
            if i1 > n - 1 { break }            // 次ブロック待ち
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
        pos = p - Double(n)                    // 次ブロック先頭基準へ rebase
        prevLast = inb[n - 1]
        return outN
    }

    // 共有領域へ attach。未接続/不健全なら 1s ゲートで再試行。
    private func ensureConnected() -> Bool {
        if connected, base != nil, healthy() { return true }

        let now = DispatchTime.now().uptimeNanoseconds
        if now &- lastTryNs < 1_000_000_000 { return false }
        lastTryNs = now

        detach()
        guard let shmOpen = Self.shmOpen else { return false }
        let f = name.withCString { shmOpen($0, O_RDWR) } // 作成しない
        if f < 0 { return false }
        let p = mmap(nil, Self.totalBytes,
                     PROT_READ | PROT_WRITE, MAP_SHARED, f, 0)
        if p == nil || p == Self.mapFailed { close(f); return false }
        fd = f
        base = p
        if !healthy() { detach(); return false }
        // sampleRate は 48k 固定（writer 側でリサンプル済）。受信側と一致。
        storeI32(p!, Self.offRate, Int32(Self.outRate))
        connected = true
        return true
    }

    private func healthy() -> Bool {
        guard let b = base else { return false }
        return loadI32(b, Self.offMagic) == Self.magic
            && loadI32(b, Self.offVersion) == Self.version
            && loadI32(b, Self.offCapacity) == Int32(Self.capacity)
            && loadI32(b, Self.offReady) == 1
    }

    private func detach() {
        if let b = base { munmap(b, Self.totalBytes); base = nil }
        if fd >= 0 { close(fd); fd = -1 }
        connected = false
    }

    // raw メモリ R/W（memcpy でアライメント非依存）。
    private func loadI32(_ b: UnsafeMutableRawPointer, _ off: Int) -> Int32 {
        var v: Int32 = 0; memcpy(&v, b.advanced(by: off), 4); return v
    }
    private func storeI32(_ b: UnsafeMutableRawPointer, _ off: Int, _ v: Int32) {
        var x = v; memcpy(b.advanced(by: off), &x, 4)
    }
    private func loadI64(_ b: UnsafeMutableRawPointer, _ off: Int) -> Int64 {
        var v: Int64 = 0; memcpy(&v, b.advanced(by: off), 8); return v
    }
    private func storeI64(_ b: UnsafeMutableRawPointer, _ off: Int, _ v: Int64) {
        var x = v; memcpy(b.advanced(by: off), &x, 8)
    }
}
