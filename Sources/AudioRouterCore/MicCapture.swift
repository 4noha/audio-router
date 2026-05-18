import AVFoundation
import CoreAudio

/// 選択した入力デバイス(マイク)を AVAudioEngine で取り込み、mono Float32 と
/// サンプルレートをコールバックで渡す。マイク権限(TCC)を明示確認し、
/// 取り込みフレーム数/ピークレベルを公開して「無音か/来てないか」を診断可能にする。
public final class MicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let deviceID: AudioObjectID
    private let useDefaultDevice: Bool
    private let onAudio: (UnsafeBufferPointer<Float>, Double) -> Void
    private var started = false

    private let lock = NSLock()
    private var _frames = 0
    private var _peak: Float = 0
    /// これまでに取り込んだ総フレーム数（0 のまま＝マイクからコールバックが来ていない）。
    public var framesDelivered: Int { lock.lock(); defer { lock.unlock() }; return _frames }
    /// 直近ブロックのピーク振幅（0 付近＝無音＝権限/デバイスを疑う）。
    public var peakLevel: Float { lock.lock(); defer { lock.unlock() }; return _peak }

    public init(deviceID: AudioObjectID,
                useDefaultDevice: Bool,
                onAudio: @escaping (UnsafeBufferPointer<Float>, Double) -> Void) {
        self.deviceID = deviceID
        self.useDefaultDevice = useDefaultDevice
        self.onAudio = onAudio
    }

    public func start() throws {
        try Self.ensureMicAuthorized()

        // 特定デバイス選択時のみ AUHAL のデバイスを指定（既定はシステム既定入力）。
        if !useDefaultDevice, let inAU = engine.inputNode.audioUnit {
            var dev = deviceID
            AudioUnitSetProperty(inAU,
                                 kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0,
                                 &dev, UInt32(MemoryLayout<AudioObjectID>.size))
        }
        let input = engine.inputNode
        let fmt = input.inputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
            throw NSError(domain: "MicCapture", code: 2, userInfo: [
                NSLocalizedDescriptionKey:
                "マイク入力フォーマット不正(sr=\(fmt.sampleRate) ch=\(fmt.channelCount))。"
                + "マイク権限または入力デバイスを確認してください"])
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) {
            [weak self] buf, _ in self?.handle(buf)
        }
        engine.prepare()
        try engine.start()
        started = true
    }

    /// マイク権限(TCC)を確認。未決定なら申請ダイアログを出し、許可後に
    /// 再トグルを促す（メインスレッドを塞がない）。
    private static func ensureMicAuthorized() throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            throw NSError(domain: "MicCapture", code: 3, userInfo: [
                NSLocalizedDescriptionKey:
                "マイク権限ダイアログを表示しました。許可してからトグルを再度 ON にしてください"])
        case .denied, .restricted:
            throw NSError(domain: "MicCapture", code: 4, userInfo: [
                NSLocalizedDescriptionKey:
                "マイク権限がありません。システム設定→プライバシーとセキュリティ"
                + "→マイク で AudioRouter を許可してください"])
        @unknown default:
            return
        }
    }

    private func handle(_ buf: AVAudioPCMBuffer) {
        guard let ch = buf.floatChannelData else { return }
        let frames = Int(buf.frameLength)
        guard frames > 0 else { return }
        let chans = Int(buf.format.channelCount)
        let sr = buf.format.sampleRate
        var peak: Float = 0
        if chans == 1 {
            let p = ch[0]
            for i in 0..<frames { let a = abs(p[i]); if a > peak { peak = a } }
            onAudio(UnsafeBufferPointer(start: p, count: frames), sr)
        } else {
            var mono = [Float](repeating: 0, count: frames)
            for f in 0..<frames {
                var acc: Float = 0
                for c in 0..<chans { acc += ch[c][f] }
                let m = acc / Float(chans)
                mono[f] = m
                let a = abs(m); if a > peak { peak = a }
            }
            mono.withUnsafeBufferPointer { onAudio($0, sr) }
        }
        lock.lock(); _frames += frames; _peak = peak; lock.unlock()
    }

    public func stop() {
        guard started else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        started = false
    }

    deinit { stop() }
}
