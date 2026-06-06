import Foundation
import Network

/// Mac → Android の戻し送信。任意の bus から 20ms フレームを切り出し、
/// Opus AUDIO モードでエンコードして登録ピアへ UDP 送信する。
///
/// 送信先は `NetAudioServer` が slot ごとに保持している lastPeer を参照する。
/// アクティブなピアがある全 slot に同じ音声をブロードキャストする
/// （= sink 行 1 つで全 Android がモニター。slot 別に流したい場合は将来
/// `targetSlot` 指定を追加する）。
@available(macOS 14.4, *)
public final class NetAudioBroadcaster: @unchecked Sendable {
    private weak var server: NetAudioServer?
    private let reader: AudioBus.Reader
    private let encoder: OpusMonoEncoder
    private let frameSize: Int                  // 480 (10ms) or 960 (20ms)
    private let codec: NetAudio.Codec = .opus

    private let q = DispatchQueue(label: "audio-router.net.broadcast",
                                  qos: .userInteractive)
    private var pump: DispatchSourceTimer?
    private var seq: UInt32 = 0
    private var scratch: [Float]                // frameSize 分の入力切出し

    private let lk = NSLock()
    private var _sent: Int64 = 0
    private var _lvl: Float = 0
    private var _bytesOut: Int64 = 0

    /// `targetSlot == nil` ならアクティブな全ピアにブロードキャスト。
    /// 指定なら当該 slot のピアにのみ送る。
    private let targetSlot: Int?

    public init(server: NetAudioServer, bus: AudioBus,
                targetSlot: Int? = nil,
                application: OpusApplication = .audio,
                // 戻し(Mac→Android)は音楽・効果音含むので 192k で頭打ち回避。
                // 20ms フレーム 1 packet ≒480byte で MTU 内に十分収まる。
                bitrate: Int32 = 192_000,
                frameSize: Int = 960) throws {
        self.server = server
        self.reader = bus.makeReader()
        self.frameSize = frameSize
        self.encoder = try OpusMonoEncoder(application: application,
                                            bitrate: bitrate,
                                            frameSize: frameSize)
        self.scratch = [Float](repeating: 0, count: frameSize)
        self.targetSlot = targetSlot
    }

    deinit { stop() }

    public func start() {
        guard pump == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: q)
        // 20ms に 1 フレーム送る（frameSize=960 のとき）。
        let intervalMs = (frameSize * 1000) / 48_000
        t.schedule(deadline: .now() + .milliseconds(intervalMs),
                   repeating: .milliseconds(intervalMs),
                   leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        pump = t
    }

    public func stop() {
        pump?.cancel(); pump = nil
    }

    private func tick() {
        // 1 フレーム読込（不足は 0 詰め＝無音）。
        let n = scratch.withUnsafeMutableBufferPointer {
            self.reader.read(into: $0)
        }
        // 全フレーム無音なら送らない（帯域・電池節約）。
        // ただし完全静音時もキープアライブとして 5 秒に 1 回は ping を流す
        // ことを検討（現状は省略）。
        var pk: Float = 0
        for i in 0..<frameSize { let a = abs(scratch[i]); if a > pk { pk = a } }
        guard pk > 0.0001 else {
            lk.lock(); _lvl = max(_lvl, pk); lk.unlock()
            return
        }

        // エンコード。
        let encoded: Data
        do {
            encoded = try scratch.withUnsafeBufferPointer { bp in
                try encoder.encode(UnsafeBufferPointer(
                    start: bp.baseAddress, count: frameSize))
            }
        } catch {
            return
        }
        _ = n  // (将来: ストリームステータスに使う)

        // 送り先 slot 解決。
        guard let server = server else { return }
        var slots: [Int] = []
        if let s = targetSlot {
            if server.peer(forSlot: s) != nil { slots.append(s) }
        } else {
            for s in 1...server.slotCount where server.peerAlive(forSlot: s) {
                slots.append(s)
            }
        }
        guard !slots.isEmpty else { return }

        // ヘッダは送る毎に seq インクリメント。slot ごとに listener 既存
        // NWConnection 経由で送信（送信元 port = listener bind port）。
        let nowUs = NetAudio.nowMicros()
        for slot in slots {
            let hdr = NetAudio.Header(
                type: .audio, slot: UInt8(slot), codec: codec,
                seq: seq, tsUs: nowUs,
                payloadLen: UInt16(encoded.count))
            let packet = NetAudio.encode(hdr, payload: encoded)
            server.send(toSlot: slot, data: packet)
        }
        seq &+= 1

        lk.lock()
        _sent &+= 1
        _bytesOut &+= Int64(encoded.count)
        if pk > _lvl { _lvl = pk }
        lk.unlock()
    }

    /// 診断: 送信フレーム数とピーク。peak は読むとリセット。
    public func snapshot() -> (sentFrames: Int64, bytesOut: Int64, peak: Float) {
        lk.lock(); defer { lk.unlock() }
        let v = (_sent, _bytesOut, _lvl)
        _lvl = 0
        return v
    }
}
