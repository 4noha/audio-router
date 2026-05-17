import Foundation
import CoreAudio

/// CoreAudio プロパティ取得の薄いヘルパ群。
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func addr(_ selector: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                     _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    /// 配列プロパティ（要素型 T）を取得。
    static func array<T>(_ object: AudioObjectID,
                         _ selector: AudioObjectPropertySelector,
                         _ type: T.Type) -> [T] {
        var address = addr(selector)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<T>.stride
        var buffer = [T](repeating: unsafeBitCast((0 as UInt64), to: T.self), count: count)
        let status = buffer.withUnsafeMutableBytes { raw -> OSStatus in
            AudioObjectGetPropertyData(object, &address, 0, nil, &dataSize, raw.baseAddress!)
        }
        guard status == noErr else { return [] }
        return buffer
    }

    /// スカラ値プロパティ（型 T）を取得。
    static func value<T>(_ object: AudioObjectID,
                         _ selector: AudioObjectPropertySelector,
                         _ initial: T) -> T? {
        var address = addr(selector)
        var dataSize = UInt32(MemoryLayout<T>.size)
        var out = initial
        let status = withUnsafeMutablePointer(to: &out) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &dataSize, $0)
        }
        return status == noErr ? out : nil
    }

    /// CFString 値プロパティを取得。
    static func string(_ object: AudioObjectID,
                       _ selector: AudioObjectPropertySelector) -> String? {
        var address = addr(selector)
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        var cf: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &cf) {
            $0.withMemoryRebound(to: CFString?.self, capacity: 1) { ptr in
                AudioObjectGetPropertyData(object, &address, 0, nil, &dataSize, ptr)
            }
        }
        guard status == noErr, let cf else { return nil }
        return cf.takeRetainedValue() as String
    }
}
