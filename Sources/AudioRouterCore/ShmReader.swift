import Darwin
import Dispatch
import CShmCompat

/// ARPS v1 共有メモリの「所有者(consumer)」側（Swift）。指定 shm を作成・
/// 初期化・破棄し、attach してきた writer(babigoe)が書く mono Float32(48k)
/// を読み出す。契約は C# Arp1ShmWriter / VoiceShmReceiver と byte 一致。
/// audio-router が /babigoe.out を所有して babigoe 出力を回収するのに使う。
public final class ShmReader: @unchecked Sendable {
    public static let nameBabigoeOut = "/babigoe.out3"

    /// babigoe 出力チャンネル名。slot=1 はレガシー `/babigoe.out3` (grandfather)、
    /// slot>=2 は §3.2 新文法 `/babigoe-out.g1.m48.<n>` (n = slot-1)。
    /// arps-shm-spec.md §5.1 台帳に対応。slot 2 = VST デッキ用 (babigoe-kai 側で書込)。
    /// 旧 `/babigoe.out3.2` (§3.3 暫定) からの移行先。
    public static func babigoeOutName(slot: Int) -> String {
        let s = max(1, min(4, slot))
        if s == 1 { return nameBabigoeOut }
        return "/babigoe-out.g1.m48.\(s - 1)"
    }

    private let name: String
    private static let magic: Int32 = 0x5350_5241   // "ARPS" LE
    private static let version: Int32 = 1

    // 音質プロファイル (§3.4)。既定 = m48 で従来挙動と byte 互換。
    private let profile: ShmProfile
    private var capacity: Int { profile.capacity }
    private var totalBytes: Int { profile.totalBytes }
    /// 既存呼び出し側互換 (m48 の SR)。多プロファイル化後は profile.sampleRate を参照。
    public static let rate: Int32 = 48_000

    private static let offMagic = 0, offVersion = 4, offRate = 8,
                       offChannels = 12, offCapacity = 16, offReady = 20,
                       offWrite = 32, offRead = 40

    private nonisolated(unsafe) static let mapFailed =
        UnsafeMutableRawPointer(bitPattern: -1)

    private var base: UnsafeMutableRawPointer?
    private var fd: Int32 = -1
    private var running = false

    public var isRunning: Bool { running }

    public init(name: String = ShmReader.nameBabigoeOut,
                profile: ShmProfile = .m48) {
        self.name = name.isEmpty ? Self.nameBabigoeOut : name
        self.profile = profile
    }

    /// 共有領域を作成・初期化（所有者）。失敗時 false。
    @discardableResult
    public func start() -> Bool {
        if running { return true }
        // macOS の shm perm は shm_open(O_CREAT) の mode でしか決まらない
        // (fchmod は EINVAL で不可)。mode は C 可変長引数なので Swift の
        // dlsym 固定引数だと arm64 ABI でゴミ化する。C シムで正規 varargs。
        var f = name.withCString { cshm_open_rw($0) }   // 既存を開く
        if f < 0 {
            f = name.withCString { cshm_open_create($0) } // O_CREAT mode0666
            if f < 0 { return false }
            _ = ftruncate(f, off_t(totalBytes))      // 新規のみ
        }
        let p = mmap(nil, totalBytes,
                     PROT_READ | PROT_WRITE, MAP_SHARED, f, 0)
        if p == nil || p == Self.mapFailed { close(f); return false }
        fd = f
        base = p

        storeI32(p!, Self.offVersion, Self.version)
        storeI32(p!, Self.offRate, profile.sampleRate)
        storeI32(p!, Self.offChannels, profile.channels)
        storeI32(p!, Self.offCapacity, Int32(capacity))
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
            munmap(b, totalBytes)
            base = nil
        }
        if fd >= 0 { close(fd); fd = -1 }
        // shm_unlink しない: unlink すると attach 済みの書き手(babigoe)が
        // orphan を掴み続け音が来なくなる。名前付き shm を安定した待ち合わせ点
        // として再利用し、再起動時は start でヘッダ再初期化のみ行う。
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
        let cap = capacity
        OSMemoryBarrier()
        let w = loadI64(base, Self.offWrite)
        var r = loadI64(base, Self.offRead)
        var avail = w - r
        if avail < 0 { avail = 0 }
        if avail > Int64(cap) { r = w - Int64(cap); avail = Int64(cap) }

        let take = Int(min(avail, Int64(n)))
        let ring = base.advanced(by: ShmProfile.headerBytes)
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
