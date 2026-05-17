import Foundation
import CoreAudio

/// audio-router を babigoe のハブとして動かす:
///   選択 mic → /babigoe.in(共有メモリ) → babigoe(声質変換) → /babigoe.out
///   → 回収 → チャンネル管理で /4ksp.voice(4ksplitter)・モニタ・UDP へ分配。
///
/// /babigoe.out を所有(ready)することが「hub 稼働中」の合図になり、
/// babigoe 側はそれを検出して入力を共有メモリへ自動切替する。
public final class HubEngine: @unchecked Sendable {
    private let micDeviceID: AudioObjectID
    private let monitorDeviceID: AudioObjectID?
    private let udpHost: String?
    private let udpPort: UInt16?

    private var mic: MicCapture?
    private var micShm: ShmSender?            // → /babigoe.in（mic 供給）
    private var outReader: ShmReader?         // ← /babigoe.out（babigoe 出力回収）
    private var toSplitter: ShmSender?        // → /4ksp.voice
    private var monitor: AudioMonitor?
    private var udp: PCMSender?

    private var pump: DispatchSourceTimer?
    private let pumpQ = DispatchQueue(label: "audio-router.hub.pump", qos: .userInteractive)
    private var pull = [Float](repeating: 0, count: 1024) // 48k mono 回収バッファ

    public private(set) var isRunning = false

    public init(micDeviceID: AudioObjectID,
                monitorDeviceID: AudioObjectID?,
                udpHost: String?, udpPort: UInt16?) {
        self.micDeviceID = micDeviceID
        self.monitorDeviceID = monitorDeviceID
        self.udpHost = udpHost
        self.udpPort = udpPort
    }

    public func start() throws {
        stop()

        // 1) babigoe 出力の回収口を所有（= hub 稼働の合図）。
        let rd = ShmReader(name: ShmReader.nameBabigoeOut)
        guard rd.start() else {
            throw NSError(domain: "HubEngine", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "/babigoe.out 作成に失敗"])
        }
        outReader = rd

        // 2) 回収音声の配り先（チャンネル管理）。
        toSplitter = ShmSender(srcSampleRate: 48_000,
                               name: ShmSender.nameToSplitter)
        if let mdev = monitorDeviceID {
            let m = AudioMonitor(deviceID: mdev, sampleRate: 48_000)
            try? m.start()
            monitor = m
        }
        if let h = udpHost, let p = udpPort {
            udp = PCMSender(host: h, port: p, channels: 1, sampleRate: 48_000)
        }

        // 3) mic → /babigoe.in。ShmSender は初回コールバックで sr 確定後に生成。
        let cap = MicCapture(deviceID: micDeviceID) { [weak self] buf, sr in
            guard let self else { return }
            if self.micShm == nil {
                self.micShm = ShmSender(srcSampleRate: sr,
                                        name: ShmSender.nameBabigoeIn)
            }
            self.micShm?.send(buf)
        }
        try cap.start()
        mic = cap

        // 4) /babigoe.out を周期的に回収して分配（~5ms）。
        let t = DispatchSource.makeTimerSource(queue: pumpQ)
        t.schedule(deadline: .now() + .milliseconds(5),
                   repeating: .milliseconds(5), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.drain() }
        t.resume()
        pump = t

        isRunning = true
    }

    private func drain() {
        guard let rd = outReader else { return }
        let got = pull.withUnsafeMutableBufferPointer { rd.read(into: $0) }
        guard got > 0 else { return }
        pull.withUnsafeBufferPointer { full in
            let buf = UnsafeBufferPointer(start: full.baseAddress, count: got)
            toSplitter?.send(buf)
            monitor?.enqueue(buf)
            udp?.send(buf)
        }
    }

    public func stop() {
        pump?.cancel(); pump = nil
        mic?.stop(); mic = nil
        micShm?.stop(); micShm = nil
        monitor?.stop(); monitor = nil
        udp?.stop(); udp = nil
        toSplitter?.stop(); toSplitter = nil
        outReader?.stop(); outReader = nil   // /babigoe.out を unlink（hub 終了）
        isRunning = false
    }

    deinit { stop() }
}
