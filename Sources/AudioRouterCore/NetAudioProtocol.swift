import Foundation

/// audio-router ↔ Android アプリ間の UDP パケット仕様。
///
/// パケット = `[22 byte header][payload bytes]` （header 含め最大 ≤1400 程度
/// に収める＝ 1 packet 1 frame 想定、フラグメント禁止で MTU 内に収まる）。
///
/// ```
/// offset  size  field
///   0     4     magic = "4NHA" (0x34 0x4E 0x48 0x41, BE 視認可能)
///   4     1     version = 1
///   5     1     type    (0=audio, 1=hello, 2=bye, 3=ping)
///   6     1     slot    (1..4, hello/bye/ping は 0 でも可)
///   7     1     codec   (0=pcm16le, 1=opus)
///   8     4     seq     (big-endian uint32, 単調増加, ラップ可)
///  12     8     ts_us   (big-endian int64, 送信側 wall clock μs)
///  20     2     payload_len (big-endian uint16, ペイロード byte 数)
///  22     N     payload
/// ```
///
/// - type=hello: 接続宣言。slot を確保したい番号で送る。payload は空。
/// - type=bye:   切断宣言。
/// - type=ping:  生存確認・往復遅延測定。payload にエコー値（任意）。
/// - type=audio: 音声 1 フレーム。codec=pcm16le なら 16-bit LE PCM、
///               codec=opus なら Opus パケット 1 個。
/// - PCM16 1 フレーム = 480 サンプル(10ms) または 960 サンプル(20ms) を想定。
public enum NetAudio {
    public static let magic: [UInt8] = [0x34, 0x4E, 0x48, 0x41]   // "4NHA"
    public static let version: UInt8 = 1
    public static let headerBytes: Int = 22
    public static let maxPacketBytes: Int = 1400

    public enum PacketType: UInt8 {
        case audio = 0
        case hello = 1
        case bye   = 2
        case ping  = 3
    }
    public enum Codec: UInt8 {
        case pcm16le = 0
        case opus    = 1
    }

    public struct Header {
        public var type: PacketType
        public var slot: UInt8        // 1..4 (other types: 0)
        public var codec: Codec
        public var seq: UInt32
        public var tsUs: Int64
        public var payloadLen: UInt16
        public init(type: PacketType, slot: UInt8, codec: Codec,
                    seq: UInt32, tsUs: Int64, payloadLen: UInt16) {
            self.type = type; self.slot = slot; self.codec = codec
            self.seq = seq; self.tsUs = tsUs; self.payloadLen = payloadLen
        }
    }

    /// `header + payload` を 1 つの Data に組み立て。
    public static func encode(_ h: Header, payload: Data) -> Data {
        var d = Data(capacity: headerBytes + payload.count)
        d.append(contentsOf: magic)
        d.append(version)
        d.append(h.type.rawValue)
        d.append(h.slot)
        d.append(h.codec.rawValue)
        d.append(UInt8((h.seq >> 24) & 0xff))
        d.append(UInt8((h.seq >> 16) & 0xff))
        d.append(UInt8((h.seq >>  8) & 0xff))
        d.append(UInt8( h.seq        & 0xff))
        let ts = UInt64(bitPattern: h.tsUs)
        d.append(UInt8((ts >> 56) & 0xff))
        d.append(UInt8((ts >> 48) & 0xff))
        d.append(UInt8((ts >> 40) & 0xff))
        d.append(UInt8((ts >> 32) & 0xff))
        d.append(UInt8((ts >> 24) & 0xff))
        d.append(UInt8((ts >> 16) & 0xff))
        d.append(UInt8((ts >>  8) & 0xff))
        d.append(UInt8( ts        & 0xff))
        d.append(UInt8((h.payloadLen >> 8) & 0xff))
        d.append(UInt8( h.payloadLen       & 0xff))
        d.append(payload)
        return d
    }

    /// `Data` から header と payload を取り出し。magic / version / payloadLen
    /// 整合チェックを行う。失敗時は nil。
    public static func decode(_ data: Data) -> (Header, Data)? {
        guard data.count >= headerBytes else { return nil }
        return data.withUnsafeBytes { (rb: UnsafeRawBufferPointer) -> (Header, Data)? in
            let p = rb.bindMemory(to: UInt8.self)
            for i in 0..<4 where p[i] != magic[i] { return nil }
            guard p[4] == version else { return nil }
            guard let type = PacketType(rawValue: p[5]) else { return nil }
            guard let codec = Codec(rawValue: p[7]) else { return nil }
            let slot = p[6]
            let seq = (UInt32(p[8]) << 24) | (UInt32(p[9]) << 16)
                | (UInt32(p[10]) << 8) | UInt32(p[11])
            var ts: UInt64 = 0
            for i in 0..<8 { ts = (ts << 8) | UInt64(p[12 + i]) }
            let plen = (UInt16(p[20]) << 8) | UInt16(p[21])
            guard headerBytes + Int(plen) <= data.count else { return nil }
            let h = Header(type: type, slot: slot, codec: codec,
                           seq: seq, tsUs: Int64(bitPattern: ts),
                           payloadLen: plen)
            let payload = data.subdata(
                in: headerBytes..<(headerBytes + Int(plen)))
            return (h, payload)
        }
    }

    /// 現時刻 (μs)。Header.tsUs 用。
    public static func nowMicros() -> Int64 {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return Int64(ts.tv_sec) * 1_000_000 + Int64(ts.tv_nsec) / 1_000
    }
}
