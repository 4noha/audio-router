import Darwin
import Foundation
import CShmCompat

// ARPS v1 動作検証 CLI。任意の shm を **作成せず attach のみ**（O_RDWR）し、
// ヘッダ（magic/version/rate/channels/capacity/ready/consumerPid/
// writeIndex/readIndex）と流量（framesPerSec）・直近ピークを JSON で出力。
// 単発スナップショット or --watch-sec で JSONL ストリーム＋サマリ。
// 読むだけなのでアプリ無改修・本経路に一切干渉しない。
//
// 使い方:
//   arps-probe --name /4ksp.voice3
//   arps-probe --name /babigoe.out3 --watch-sec 3 --interval-ms 250 --require-flow
//
// exit code: 0=正常(attached & ARPS ok / --require-flow 時は流量あり)
//            2=attach 不可 or ヘッダ不正   3=--require-flow で流量なし
//            64=引数不正

// ---- ARPS v1 オフセット（ShmReader/ShmSender と byte 一致）----
let OFF_MAGIC = 0, OFF_VER = 4, OFF_RATE = 8, OFF_CH = 12,
    OFF_CAP = 16, OFF_READY = 20, OFF_PID = 24, OFF_W = 32, OFF_R = 40
let HEADER = 64
let MAGIC: Int32 = 0x5350_5241          // "ARPS" LE
let CAP_FRAMES = 96_000
let TOTAL = HEADER + CAP_FRAMES * 4

let argv = CommandLine.arguments
func opt(_ k: String) -> String? {
    guard let i = argv.firstIndex(of: k), i + 1 < argv.count else { return nil }
    return argv[i + 1]
}
func flag(_ k: String) -> Bool { argv.contains(k) }

guard let name = opt("--name"), !name.isEmpty else {
    FileHandle.standardError.write(Data("""
    usage: arps-probe --name <shm> [--watch-sec N] [--interval-ms M] [--require-flow]

    """.utf8))
    exit(64)
}
let watchSec = Double(opt("--watch-sec") ?? "0") ?? 0
let intervalMs = max(20, Int(opt("--interval-ms") ?? "250") ?? 250)
let requireFlow = flag("--require-flow")

func emit(_ d: [String: Any]) {
    if let j = try? JSONSerialization.data(withJSONObject: d),
       let s = String(data: j, encoding: .utf8) {
        print(s); fflush(stdout)
    }
}
func fail(_ msg: String, code: Int32) -> Never {
    emit(["name": name, "attached": false, "error": msg]); exit(code)
}

// attach のみ（作成しない）。失敗＝まだ誰も shm を作っていない。
let fd = name.withCString { cshm_open_rw($0) }
if fd < 0 { fail("shm_open(O_RDWR): \(String(cString: strerror(errno)))", code: 2) }

var st = stat()
let size = fstat(fd, &st) == 0 ? Int(st.st_size) : 0
let mapLen = size > 0 ? min(size, TOTAL) : TOTAL
if mapLen < HEADER { close(fd); fail("shm too small (\(size)B)", code: 2) }

let MAP_FAILED_PTR = UnsafeMutableRawPointer(bitPattern: -1)
guard let base = mmap(nil, mapLen, PROT_READ, MAP_SHARED, fd, 0),
      base != MAP_FAILED_PTR else {
    close(fd); fail("mmap: \(String(cString: strerror(errno)))", code: 2)
}

func i32(_ o: Int) -> Int32 { var v: Int32 = 0; memcpy(&v, base + o, 4); return v }
func i64(_ o: Int) -> Int64 { var v: Int64 = 0; memcpy(&v, base + o, 8); return v }

let magic = i32(OFF_MAGIC)
let arpsOk = magic == MAGIC
let ver = i32(OFF_VER), rate = i32(OFF_RATE), ch = i32(OFF_CH)
let capHdr = i32(OFF_CAP), ready = i32(OFF_READY)
let ringBytes = mapLen - HEADER
let ringCap = capHdr > 0 ? Int(capHdr) : CAP_FRAMES

// writeIndex 直前 ~100ms の絶対ピーク（passive 読み、readIndex 不変更）。
func peak() -> Float {
    guard arpsOk, ringCap > 0 else { return 0 }
    let w = i64(OFF_W)
    let want = Int(Double(max(rate, 1)) * 0.1)
    let avail = min(ringBytes / 4, ringCap)
    let k = min(want, avail, Int(w))
    if k <= 0 { return 0 }
    let ring = base + HEADER
    var idx = Int((w - Int64(k)) % Int64(ringCap))
    if idx < 0 { idx += ringCap }
    var mx: Float = 0
    for _ in 0..<k {
        if (idx + 1) * 4 <= ringBytes {
            var f: Float = 0; memcpy(&f, ring + idx * 4, 4)
            let a = f < 0 ? -f : f
            if a > mx { mx = a }
        }
        idx = (idx + 1) % ringCap
    }
    return mx
}

func consumerAlive(_ p: Int32) -> Bool {
    guard p > 0 else { return false }
    return kill(pid_t(p), 0) == 0 || errno == EPERM
}

func snapshot(prevW: Int64?, dt: Double) -> [String: Any] {
    let w = i64(OFF_W), r = i64(OFF_R), pid = i32(OFF_PID)
    var o: [String: Any] = [
        "name": name, "attached": true, "arpsOk": arpsOk,
        "version": Int(ver), "rate": Int(rate), "channels": Int(ch),
        "capacity": Int(capHdr), "ready": Int(ready),
        "writeIndex": w, "readIndex": r, "backlog": max(0, w - r),
        "consumerPid": Int(pid), "consumerAlive": consumerAlive(pid),
        "peak": Double(peak()), "sizeBytes": size,
        "ts": Date().timeIntervalSince1970
    ]
    if let p = prevW, dt > 0 { o["framesPerSec"] = Double(w - p) / dt }
    return o
}

if watchSec <= 0 {
    emit(snapshot(prevW: nil, dt: 0))
    munmap(base, mapLen); close(fd)
    exit(arpsOk ? 0 : 2)
}

let start = Date()
let firstW = i64(OFF_W)
var prevW = firstW
var last = Date()
while Date().timeIntervalSince(start) < watchSec {
    usleep(UInt32(intervalMs * 1000))
    let now = Date()
    let dt = now.timeIntervalSince(last); last = now
    emit(snapshot(prevW: prevW, dt: dt))
    prevW = i64(OFF_W)
}
let advanced = prevW - firstW
var summary = snapshot(prevW: nil, dt: 0)
summary["summary"] = true
summary["advancedFrames"] = advanced
summary["flow"] = advanced > 0
emit(summary)
munmap(base, mapLen); close(fd)
if requireFlow { exit(advanced > 0 ? 0 : 3) }
exit(arpsOk ? 0 : 2)
