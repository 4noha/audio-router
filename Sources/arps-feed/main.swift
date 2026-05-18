import Darwin
import Foundation
import CShmCompat

// E2E 合成音源 CLI。指定 shm を **作成・初期化（owner）** し、mono Float32
// 48k の正弦波を ~10ms ブロックでリングへ書き込み続ける。audio-router の
// ShmInEdge が読む側（例 /babigoe.out3）を Claude から無人で供給するための
// 決定論的テストソース。shm_unlink しない（既存の待ち合わせ規約に準拠）。
//
// 使い方:
//   arps-feed --name /babigoe.out3 --hz 440 --amp 0.3 --duration-sec 5
//
// exit code: 0=正常終了 / 2=shm 作成不可 / 64=引数不正

let OFF_MAGIC = 0, OFF_VER = 4, OFF_RATE = 8, OFF_CH = 12,
    OFF_CAP = 16, OFF_READY = 20, OFF_W = 32, OFF_R = 40
let HEADER = 64
let MAGIC: Int32 = 0x5350_5241
let CAP_FRAMES = 96_000
let TOTAL = HEADER + CAP_FRAMES * 4

let argv = CommandLine.arguments
func opt(_ k: String) -> String? {
    guard let i = argv.firstIndex(of: k), i + 1 < argv.count else { return nil }
    return argv[i + 1]
}
guard let name = opt("--name"), !name.isEmpty else {
    FileHandle.standardError.write(Data("""
    usage: arps-feed --name <shm> [--hz 440] [--amp 0.3] [--duration-sec 5] [--rate 48000]

    """.utf8))
    exit(64)
}
let hz = Double(opt("--hz") ?? "440") ?? 440
let amp = Float(opt("--amp") ?? "0.3") ?? 0.3
let durSec = Double(opt("--duration-sec") ?? "5") ?? 5
let rate = Int32(opt("--rate") ?? "48000") ?? 48_000

// 既存を開く→無ければ作成（正規 C 可変長 mode で perm 0666）。
var fd = name.withCString { cshm_open_rw($0) }
var created = false
if fd < 0 {
    fd = name.withCString { cshm_open_create($0) }
    if fd < 0 {
        FileHandle.standardError.write(Data("shm_open_create failed: \(String(cString: strerror(errno)))\n".utf8))
        exit(2)
    }
    _ = ftruncate(fd, off_t(TOTAL))
    created = true
}
let MAP_FAILED_PTR = UnsafeMutableRawPointer(bitPattern: -1)
guard let base = mmap(nil, TOTAL, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
      base != MAP_FAILED_PTR else {
    FileHandle.standardError.write(Data("mmap failed\n".utf8)); exit(2)
}

func st32(_ o: Int, _ v: Int32) { var x = v; memcpy(base + o, &x, 4) }
func st64(_ o: Int, _ v: Int64) { var x = v; memcpy(base + o, &x, 8) }
func ld64(_ o: Int) -> Int64 { var v: Int64 = 0; memcpy(&v, base + o, 8); return v }
func ld32(_ o: Int) -> Int32 { var v: Int32 = 0; memcpy(&v, base + o, 4); return v }

// 新規 or 未初期化（magic 不一致）ならヘッダ初期化（最後に ready=1）。
if created || ld32(OFF_MAGIC) != MAGIC {
    st32(OFF_VER, 1)
    st32(OFF_RATE, rate)
    st32(OFF_CH, 1)
    st32(OFF_CAP, Int32(CAP_FRAMES))
    st64(OFF_W, 0)
    st64(OFF_R, 0)
    st32(OFF_MAGIC, MAGIC)
    OSMemoryBarrier()
    st32(OFF_READY, 1)
}

let ring = base + HEADER
let blockMs = 10
let blockN = Int(rate) * blockMs / 1000          // 10ms ぶんの frames
let step = 2.0 * Double.pi * hz / Double(rate)
var phase = 0.0
var buf = [Float](repeating: 0, count: blockN)

let start = Date()
while Date().timeIntervalSince(start) < durSec {
    for i in 0..<blockN {
        buf[i] = amp * Float(sin(phase))
        phase += step
        if phase > 2.0 * Double.pi { phase -= 2.0 * Double.pi }
    }
    let w = ld64(OFF_W)
    let begin = Int(w % Int64(CAP_FRAMES))
    buf.withUnsafeBytes { raw in
        let src = raw.baseAddress!
        if begin + blockN <= CAP_FRAMES {
            (ring + begin * 4).copyMemory(from: src, byteCount: blockN * 4)
        } else {
            let first = CAP_FRAMES - begin
            (ring + begin * 4).copyMemory(from: src, byteCount: first * 4)
            ring.copyMemory(from: src + first * 4,
                            byteCount: (blockN - first) * 4)
        }
    }
    OSMemoryBarrier()
    st64(OFF_W, w + Int64(blockN))
    OSMemoryBarrier()
    usleep(UInt32(blockMs * 1000))
}

munmap(base, TOTAL)
close(fd)
exit(0)
