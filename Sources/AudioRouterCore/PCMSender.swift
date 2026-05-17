import Foundation
import Network

/// README の「ワイヤーフォーマット v1」で 4ksplitter へ UDP 送出する。
/// 16 byte ヘッダ + interleaved Float32 LE ペイロード。再送なし・ロス許容。
public final class PCMSender: @unchecked Sendable {
    public static let magic: [UInt8] = [0x41, 0x52, 0x50, 0x31] // "ARP1"
    public static let version: UInt8 = 1

    private let queue = DispatchQueue(label: "audio-router.pcm-sender")
    private var connection: NWConnection?
    private var seq: UInt32 = 0
    private let channels: UInt8
    private let sampleRate: UInt32
    /// 1 データグラム最大サンプル数（IP フラグメント回避: ~1200B / 4）
    private let maxSamplesPerPacket = 288

    public init(host: String, port: UInt16, channels: UInt8, sampleRate: UInt32) {
        self.channels = channels
        self.sampleRate = sampleRate
        let conn = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 7878,
            using: .udp)
        conn.start(queue: queue)
        self.connection = conn
    }

    public func stop() {
        queue.async { [weak self] in
            self?.connection?.cancel()
            self?.connection = nil
        }
    }

    /// interleaved Float32 サンプル列を送出（必要に応じ複数データグラムに分割）。
    public func send(_ samples: UnsafeBufferPointer<Float>) {
        let total = samples.count
        guard total > 0 else { return }
        let frameStride = Int(max(channels, 1))
        var offset = 0
        while offset < total {
            let take = min(maxSamplesPerPacket * frameStride, total - offset)
            var packet = Data(capacity: 16 + take * 4)
            packet.append(contentsOf: Self.magic)
            packet.append(Self.version)
            packet.append(channels)
            packet.append(0); packet.append(0)              // reserved
            withUnsafeBytes(of: sampleRate.littleEndian) { packet.append(contentsOf: $0) }
            withUnsafeBytes(of: seq.littleEndian) { packet.append(contentsOf: $0) }
            samples.baseAddress!.advanced(by: offset)
                .withMemoryRebound(to: UInt8.self, capacity: take * 4) { p in
                    packet.append(p, count: take * 4)
                }
            seq &+= 1
            offset += take
            connection?.send(content: packet, completion: .idempotent)
        }
    }
}
