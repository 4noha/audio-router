import Darwin
import Dispatch

/// ARPS v1 共有メモリの「所有者(consumer)」側（Swift）。指定 shm を作成・
/// 初期化・破棄し、attach してきた writer(babigoe)が書く mono Float32(48k)
/// を読み出す。契約は C# Arp1ShmWriter / VoiceShmReceiver と byte 一致。
/// audio-router が /babigoe.out を所有して babigoe 出力を回収するのに使う。
public final class ShmReader: @unchecked Sendable {
    public static let nameBabigoeOut = "/babigoe.out"

    private let name: String
    private static let magic: Int32 = 0x5350_5241   // "ARPS" LE
    private static let version: Int32 = 1
    private static let capacity = 96_000
    private static let headerBytes = 64
    private static let totalBytes = headerBytes + capacity * 4
    public static let rate: Int32 = 48_000

    private static let offMagic = 0, offVersion = 4, offRate = 8,
                       offChannels = 12, offCapacity = 16, offReady = 20,
                       offWrite = 32, offRead = 40

    // shm_open は C 可変長。O_CREAT を使うため mode 付き 3 引数固定の
    // C 関数ポインタとして dlsym で解決して呼ぶ。
    private typealias ShmOpenFn =
        @convention(c) (UnsafePointer<CChar>, Int32, UInt16) -> Int32
    private static let shmOpen: ShmOpenFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "shm_open")
        else { return nil }
        return unsafeBitCast(sym, to: ShmOpenFn.self)
    }()
    private nonisolated(unsafe) static let mapFailed =
        UnsafeMutableRawPointer(bitPattern: -1)

    private var base: UnsafeMutableRawPointer?
    private var fd: Int32 = -1
    private var running = false

    public var isRunning: Bool { running }

    public init(name: String = ShmReader.nameBabigoeOut) {
        self.name = name.isEmpty ? Self.nameBabigoeOut : name
    }

    /// 共有領域を作成・初期化（所有者）。失敗時 false。
    @discardableResult
    public func start() -> Bool {
        if running { return true }
        guard let shmOpen = Self.shmOpen else { return false }
        let f = name.withCString { shmOpen($0, O_RDWR | O_CREAT, 0o600) }
        if f < 0 { return false }
        if ftruncate(f, off_t(Self.totalBytes)) != 0 { close(f); return false }
        let p = mmap(nil, Self.totalBytes,
                     PROT_READ | PROT_WRITE, MAP_SHARED, f, 0)
        if p == nil || p == Self.mapFailed { close(f); return false }
        fd = f
        base = p

        storeI32(p!, Self.offVersion, Self.version)
        storeI32(p!, Self.offRate, Self.rate)
        storeI32(p!, Self.offChannels, 1)
        storeI32(p!, Self.offCapacity, Int32(Self.capacity))
        storeI64(p!, Self.offWrite, 0)
        storeI64(p!, Self.offRead, 0)
        storeI32(p!, Self.offMagic, Self.magic)
        OSMemoryBarrier()
        storeI32(p!, Self.offReady, 1)
        running = true
        return true
    }

    public func stop() {
        running = false
        if let b = base {
            storeI32(b, Self.offReady, 0)
            munmap(b, Self.totalBytes)
            base = nil
        }
        if fd >= 0 { close(fd); fd = -1 }
        name.withCString { _ = shm_unlink($0) }
    }

    deinit { stop() }

    /// mono Float32(48k)を dst へ充填し実データ数を返す（不足は無音）。
    @discardableResult
    public func read(into dst: UnsafeMutableBufferPointer<Float>) -> Int {
        let n = dst.count
        guard running, let base = base, n > 0 else {
            if let p = dst.baseAddress { p.update(repeating: 0, count: n) }
            return 0
        }
        let cap = Self.capacity
        OSMemoryBarrier()
        let w = loadI64(base, Self.offWrite)
        var r = loadI64(base, Self.offRead)
        var avail = w - r
        if avail < 0 { avail = 0 }
        if avail > Int64(cap) { r = w - Int64(cap); avail = Int64(cap) }

        let take = Int(min(avail, Int64(n)))
        let ring = base.advanced(by: Self.headerBytes)
        if take > 0, let outp = dst.baseAddress {
            let start = Int(r % Int64(cap))
            if start + take <= cap {
                memcpy(outp, ring.advanced(by: start * 4), take * 4)
            } else {
                let first = cap - start
                memcpy(outp, ring.advanced(by: start * 4), first * 4)
                memcpy(outp.advanced(by: first),
                       ring, (take - first) * 4)
            }
        }
        if let outp = dst.baseAddress, take < n {
            (outp + take).update(repeating: 0, count: n - take)
        }
        storeI64(base, Self.offRead, r + Int64(take))
        OSMemoryBarrier()
        return take
    }

    // raw メモリ R/W（memcpy でアライメント非依存）。
    private func loadI64(_ b: UnsafeMutableRawPointer, _ off: Int) -> Int64 {
        var v: Int64 = 0; memcpy(&v, b.advanced(by: off), 8); return v
    }
    private func storeI64(_ b: UnsafeMutableRawPointer, _ off: Int, _ v: Int64) {
        var x = v; memcpy(b.advanced(by: off), &x, 8)
    }
    private func storeI32(_ b: UnsafeMutableRawPointer, _ off: Int, _ v: Int32) {
        var x = v; memcpy(b.advanced(by: off), &x, 4)
    }
}
