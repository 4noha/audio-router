import Foundation
import COpus

/// libopus の薄いラッパ。mono 48k Float32 固定。
///
/// 入力フレーム長は 48k での frame_size 制約に従う:
///   120 / 240 / 480 / 960 / 1920 / 2880 サンプル (= 2.5/5/10/20/40/60 ms)
/// audio-router では 480 (10ms) または 960 (20ms) を主に使う。
///
/// アプリケーションモード:
///   - .voip : 音声特化（喋り）。低ビットレート向き、口音以外を多少歪める。
///   - .audio: 任意音（音楽・効果音・ミックス）。MP3/AAC を凌ぐ品質を低
///             レイテンシで提供。Spotify/YouTube も採用。
///   - .lowdelay: VOIP より更に低 latency 最優先。LAN 用途ではここまで
///             詰めなくて良いので未使用。
public enum OpusApplication: Int32 {
    case voip = 2048          // OPUS_APPLICATION_VOIP
    case audio = 2049         // OPUS_APPLICATION_AUDIO
    case lowdelay = 2051      // OPUS_APPLICATION_RESTRICTED_LOWDELAY
}

public enum OpusError: Error {
    case createFailed(Int32)
    case encodeFailed(Int32)
    case decodeFailed(Int32)
    case badArgument(String)
}

/// 48k mono Float32 専用 Opus エンコーダ。
public final class OpusMonoEncoder: @unchecked Sendable {
    private let st: OpaquePointer
    /// 1 フレームのサンプル数（120/240/480/960/1920/2880 のいずれか）。
    public let frameSize: Int
    /// 出力 1 フレームの上限バイト数（Opus 推奨の安全側上限）。
    public let maxPayloadBytes: Int = 4000

    public init(application: OpusApplication = .voip,
                bitrate: Int32 = 32_000,
                frameSize: Int = 960) throws {
        var err: Int32 = 0
        // opus_encoder_create(Fs=48000, channels=1, application, &error)
        guard let enc = opus_encoder_create(48_000, 1, application.rawValue, &err),
              err == 0
        else { throw OpusError.createFailed(err) }
        self.st = enc
        self.frameSize = frameSize
        // OPUS_SET_BITRATE_REQUEST = 4002
        _ = copus_encoder_set_int(enc, 4002, Int32(bitrate))
        // OPUS_SET_SIGNAL_REQUEST = 4024
        // VOIP は signal=voice (3001), AUDIO は signal=music (3002)。
        let signal: Int32 = (application == .voip) ? 3001 : 3002
        _ = copus_encoder_set_int(enc, 4024, signal)
        // OPUS_SET_INBAND_FEC_REQUEST = 4012 (1=on)
        _ = copus_encoder_set_int(enc, 4012, Int32(1))
        // OPUS_SET_PACKET_LOSS_PERC_REQUEST = 4014 (LAN 想定で 5%)
        _ = copus_encoder_set_int(enc, 4014, Int32(5))
    }

    deinit { opus_encoder_destroy(st) }

    /// `samples.count` は `frameSize` ぴったり必須。返り値は encoded データ。
    public func encode(_ samples: UnsafeBufferPointer<Float>) throws -> Data {
        guard samples.count == frameSize, let base = samples.baseAddress
        else { throw OpusError.badArgument("expected \(frameSize) samples, got \(samples.count)") }
        var buf = [UInt8](repeating: 0, count: maxPayloadBytes)
        let n = buf.withUnsafeMutableBufferPointer { bp -> Int32 in
            opus_encode_float(st, base, Int32(frameSize),
                              bp.baseAddress!, Int32(maxPayloadBytes))
        }
        if n < 0 { throw OpusError.encodeFailed(n) }
        return Data(buf.prefix(Int(n)))
    }
}

/// 48k mono Float32 専用 Opus デコーダ。
public final class OpusMonoDecoder: @unchecked Sendable {
    private let st: OpaquePointer
    /// デコード時に渡せる pcm バッファ長の最大（120ms ぶん）。
    public let maxFrameSize: Int = 5760

    public init() throws {
        var err: Int32 = 0
        guard let dec = opus_decoder_create(48_000, 1, &err), err == 0
        else { throw OpusError.createFailed(err) }
        self.st = dec
    }

    deinit { opus_decoder_destroy(st) }

    /// data == nil または空のとき PLC (フレームロス補完)。返り値は出力 PCM。
    public func decode(_ data: Data?, expectedFrameSize: Int = 0) throws -> [Float] {
        var out = [Float](repeating: 0, count: maxFrameSize)
        let n = try out.withUnsafeMutableBufferPointer { op -> Int32 in
            if let data, !data.isEmpty {
                return try data.withUnsafeBytes { rb -> Int32 in
                    guard let p = rb.baseAddress else { throw OpusError.badArgument("nil data") }
                    return opus_decode_float(st,
                                              p.assumingMemoryBound(to: UInt8.self),
                                              Int32(data.count),
                                              op.baseAddress!,
                                              Int32(maxFrameSize),
                                              0)
                }
            } else {
                // PLC（ロスト検出時）
                let fs = expectedFrameSize > 0 ? expectedFrameSize : 960
                return opus_decode_float(st, nil, 0,
                                          op.baseAddress!, Int32(fs), 0)
            }
        }
        if n < 0 { throw OpusError.decodeFailed(n) }
        return Array(out.prefix(Int(n)))
    }
}
