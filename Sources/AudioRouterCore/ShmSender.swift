import Foundation
import Darwin
import Dispatch
import CShmCompat

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
    public static let nameToSplitter = "/4ksp.voice3"  // 4ksplitter 受信(枠1=レガシー)
    public static let nameBabigoeIn  = "/babigoe.in3"  // babigoe へ mic 供給
    public static let nameObsMicBase   = "/obs.mic3"   // OBS マイク受信(枠1=接尾辞無し)
    public static let nameObsVideoBase = "/obs.video3" // OBS 映像音受信(枠1=接尾辞無し)

    /// 4ksplitter のモデル枠(1..4)→shm 名。枠1 はレガシー名据置で
    /// 既存ルートと完全後方互換。枠2..4 は同契約(ARPS v1/mono48k)別 shm。
    public static func splitterName(slot: Int) -> String {
        let s = max(1, min(4, slot))
        return s == 1 ? nameToSplitter : "\(nameToSplitter).\(s)"
    }

    /// OBS 受信スロット名。kind="mic"(1..4) / "video"(1..2)。同契約(ARPS v1
    /// /mono48k)、枠1 は接尾辞無し（splitter と同じ文法）。
    public static func obsName(kind: String, slot: Int) -> String {
        let base = kind == "video" ? nameObsVideoBase : nameObsMicBase
        let maxSlot = kind == "video" ? 2 : 4
        let s = max(1, min(maxSlot, slot))
        return s == 1 ? base : "\(base).\(s)"
    }

    /// babigoe 入力チャンネル名。slot=1 はレガシー `/babigoe.in3` (grandfather)、
    /// slot>=2 は §3.2 新文法 `/babigoe-in.g1.m48.<n>` (n = slot-1)。
    /// arps-shm-spec.md §5.1 台帳に対応。slot 2 = VST デッキ用 (babigoe-kai 側で attach)。
    /// 旧 `/babigoe.in3.2` (§3.3 暫定) からの移行先。
    public static func babigoeInName(slot: Int) -> String {
        let s = max(1, min(4, slot))
        if s == 1 { return nameBabigoeIn }
        return "/babigoe-in.g1.m48.\(s - 1)"
    }
    private let name: String
    private static let magic: Int32 = 0x5350_5241   // "ARPS" LE
    private static let version: Int32 = 1

    // 音質プロファイル (§3.4)。既定 = m48 で従来挙動と byte 互換。
    // 他プロファイルは送信は mono 経路のため m44/m96 までは設定可能。
    // ステレオは Send/resample がまだ mono 前提のため要件出るまで非対応。
    private let profile: ShmProfile
    private var capacity: Int { profile.capacity }
    private var totalBytes: Int { profile.totalBytes }
    private var outRate: Double { Double(profile.sampleRate) }

    // ヘッダオフセット
    private static let offMagic = 0, offVersion = 4, offRate = 8,
                       offChannels = 12, offCapacity = 16, offReady = 20,
                       offConsumerPid = 24,
                       offWrite = 32, offRead = 40

    // shm 作成は本 writer(Swift=C シム)が一手に担い、正しい mode(0666)で
    // 生成＋ヘッダ初期化する。C# 側(4ksplitter/babigoe)は attach のみ。
    private nonisolated(unsafe) static let mapFailed =
        UnsafeMutableRawPointer(bitPattern: -1)

    private var base: UnsafeMutableRawPointer?
    private var fd: Int32 = -1
    private var lastTryNs: UInt64 = 0
    private var connected = false

    // 診断（RouterController が UI 行に毎秒表示）。
    private let dlock = NSLock()
    private var _sent = 0
    private var _connDiag = false
    private var _lastErrno: Int32 = 0
    public var statusLine: String {
        dlock.lock(); defer { dlock.unlock() }
        return _connDiag ? "shm conn=Y sent=\(_sent)"
                         : "shm conn=N err=\(_lastErrno)"
    }
    /// 累積送出フレーム数（こちらが書いた量。受信側の有無は不問）。
    public var sentFrames: Int { dlock.lock(); defer { dlock.unlock() }; return _sent }
    /// 受信側が読み進めた累積フレーム数（readIndex）。受信側(4ksplitter等)
    /// が止まると進まない＝「相手が実際に受信しているか」の判定に使う。
    public var consumedFrames: Int {
        guard let b = base else { return 0 }
        return Int(loadI64(b, Self.offRead))
    }
    /// 受信側が公開した PID（未 attach なら 0）。
    public var consumerPid: Int32 {
        guard let b = base else { return 0 }
        return loadI32(b, Self.offConsumerPid)
    }
    /// 受信プロセスが生存しているか（kill(pid,0) で直接確認）。
    /// pid 未公開(0)＝まだ誰も繋がっていない → false。
    public var consumerAlive: Bool {
        let pid = consumerPid
        guard pid > 0 else { return false }
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM   // EPERM=存在(権限差) / ESRCH=不在
    }

    // ストリーミング線形リサンプラ状態（srcRate→48k, ブロック跨ぎ連続）
    private let srcRate: Double
    private let step: Double
    private var pos: Double = 0
    private var prevLast: Float = 0
    private var out = [Float](repeating: 0, count: 4096)

    public init(srcSampleRate: Double,
                name: String = ShmSender.nameToSplitter,
                profile: ShmProfile = .m48) {
        self.profile = profile
        self.name = name.isEmpty ? Self.nameToSplitter : name
        let outR = Double(profile.sampleRate)
        self.srcRate = srcSampleRate > 0 ? srcSampleRate : outR
        self.step = self.srcRate / outR
    }

    /// データ到来前でも shm を作成・初期化して所有しておく（受信側が
    /// すぐ attach できるよう、OUT エッジ start 時/毎 tick に呼ぶ）。
    /// 接続済みなら即 return（軽量）。
    public func open() { _ = ensureConnected() }

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

        let cap = capacity
        let w = loadI64(base, Self.offWrite)
        let start = Int(w % Int64(cap))
        let ring = base.advanced(by: ShmProfile.headerBytes)

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
        dlock.lock(); _sent += outN; dlock.unlock()
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

    // 共有領域を作成(C シムで正規 mode 0666)＋ヘッダ初期化して所有。
    // 未接続なら 1s ゲートで再試行。
    private func ensureConnected() -> Bool {
        if connected, base != nil { return true }

        let now = DispatchTime.now().uptimeNanoseconds
        if now &- lastTryNs < 1_000_000_000 { return false }
        lastTryNs = now

        detach()
        var f = name.withCString { cshm_open_rw($0) }     // 既存を開く
        var freshlyCreated = false
        if f < 0 {
            f = name.withCString { cshm_open_create($0) } // O_CREAT mode0666
            if f < 0 {
                dlock.lock(); _lastErrno = errno; dlock.unlock()
                return false
            }
            _ = ftruncate(f, off_t(totalBytes))
            freshlyCreated = true
        }
        let p = mmap(nil, totalBytes,
                     PROT_READ | PROT_WRITE, MAP_SHARED, f, 0)
        if p == nil || p == Self.mapFailed { close(f); return false }
        fd = f
        base = p

        // 新規 or 未初期化(magic 不一致)ならヘッダ初期化（最後に ready=1）。
        if freshlyCreated || loadI32(p!, Self.offMagic) != Self.magic {
            storeI32(p!, Self.offVersion, Self.version)
            storeI32(p!, Self.offRate, profile.sampleRate)
            storeI32(p!, Self.offChannels, profile.channels)
            storeI32(p!, Self.offCapacity, Int32(capacity))
            storeI64(p!, Self.offWrite, 0)
            storeI64(p!, Self.offRead, 0)
            storeI32(p!, Self.offMagic, Self.magic)
            OSMemoryBarrier()
            storeI32(p!, Self.offReady, 1)
        }
        connected = true
        dlock.lock(); _connDiag = true; dlock.unlock()
        return true
    }

    private func detach() {
        if let b = base { munmap(b, totalBytes); base = nil }
        if fd >= 0 { close(fd); fd = -1 }
        connected = false
        dlock.lock(); _connDiag = false; dlock.unlock()
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
