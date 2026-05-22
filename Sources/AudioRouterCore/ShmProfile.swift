import Foundation

/// ARPS shm 仕様 §3.4 音質プロファイル。チャンネル数とサンプルレートから
/// capacity (= SR × 2秒) と totalBytes が決まる。ヘッダ §2 構造は不変。
/// 既定 = m48 (元仕様と byte 一致)。新プロファイルを足したらここに追加。
public struct ShmProfile: Sendable, Equatable {
    public let code: String          // "m48" / "st48" / "m96" 等
    public let channels: Int32
    public let sampleRate: Int32     // Hz
    public let capacity: Int         // frames = sampleRate * 2
    public static let headerBytes: Int = 64
    public var totalBytes: Int { Self.headerBytes + capacity * 4 * Int(channels) }

    public init(code: String, channels: Int32, sampleRate: Int32) {
        self.code = code
        self.channels = channels
        self.sampleRate = sampleRate
        self.capacity = Int(sampleRate) * 2
    }

    // 仕様書 §3.4 プロファイル台帳。
    public static let m48  = ShmProfile(code: "m48",  channels: 1, sampleRate: 48_000)
    public static let m44  = ShmProfile(code: "m44",  channels: 1, sampleRate: 44_100)
    public static let m96  = ShmProfile(code: "m96",  channels: 1, sampleRate: 96_000)
    public static let st48 = ShmProfile(code: "st48", channels: 2, sampleRate: 48_000)
    public static let st44 = ShmProfile(code: "st44", channels: 2, sampleRate: 44_100)
    public static let st96 = ShmProfile(code: "st96", channels: 2, sampleRate: 96_000)

    /// 名前文法 `/<ns>.<gen>.<fmt>.<slot>` の `<fmt>` トークンから逆引き。
    /// 既定 (レガシー名や未知 fmt) は M48。
    public static func from(code: String) -> ShmProfile {
        switch code {
        case "m48":  return m48
        case "m44":  return m44
        case "m96":  return m96
        case "st48": return st48
        case "st44": return st44
        case "st96": return st96
        default:     return m48
        }
    }
}
