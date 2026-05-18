import Foundation
import CoreAudio
import AudioRouterCore

/// 1 エッジの実行体。stop で停止、diag で毎秒の診断文字列。
@available(macOS 14.4, *)
protocol EdgeEngine: AnyObject {
    func stop()
    var diag: String { get }
}

// MARK: - IN: アプリタップ → bus

@available(macOS 14.4, *)
final class TapInEdge: EdgeEngine {
    private let tap = ProcessTapEngine()
    private var rs: LinearResampler?
    private let bus: AudioBus
    private let lk = NSLock()
    private var frames = 0
    private var peak: Float = 0

    init(processObject: AudioObjectID, muteSource: Bool, bus: AudioBus) throws {
        self.bus = bus
        tap.onMono = { [weak self] buf, sr in
            guard let self else { return }
            if self.rs == nil {
                self.rs = LinearResampler(srcRate: sr,
                                          dstRate: Double(AudioBus.rate))
            }
            var pk: Float = 0
            for v in buf { let a = v < 0 ? -v : v; if a > pk { pk = a } }
            self.rs?.process(buf) { self.bus.write($0) }
            self.lk.lock(); self.frames += buf.count; self.peak = pk; self.lk.unlock()
        }
        try tap.startCapture(processObject: processObject, muteSource: muteSource)
    }
    func stop() { tap.stop() }
    var diag: String {
        lk.lock(); defer { lk.unlock() }
        return "in=\(frames) lvl=\(String(format: "%.3f", peak))"
    }
}

// MARK: - IN: マイク → bus

@available(macOS 14.4, *)
final class MicInEdge: EdgeEngine {
    private var mic: MicCapture?
    private var rs: LinearResampler?
    private let bus: AudioBus
    private let lk = NSLock()
    private var frames = 0
    private var peak: Float = 0

    init(deviceID: AudioObjectID, useDefault: Bool, bus: AudioBus) throws {
        self.bus = bus
        let cap = MicCapture(deviceID: deviceID,
                             useDefaultDevice: useDefault) { [weak self] buf, sr in
            guard let self else { return }
            if self.rs == nil {
                self.rs = LinearResampler(srcRate: sr,
                                          dstRate: Double(AudioBus.rate))
            }
            var pk: Float = 0
            for v in buf { let a = v < 0 ? -v : v; if a > pk { pk = a } }
            self.rs?.process(buf) { self.bus.write($0) }
            self.lk.lock(); self.frames += buf.count; self.peak = pk; self.lk.unlock()
        }
        try cap.start()
        mic = cap
    }
    func stop() { mic?.stop(); mic = nil }
    var diag: String {
        lk.lock(); defer { lk.unlock() }
        return "in=\(frames) lvl=\(String(format: "%.3f", peak))"
    }
}

// MARK: - IN: babigoe(/babigoe.out) → bus

@available(macOS 14.4, *)
final class ShmInEdge: EdgeEngine {
    private let reader: ShmReader
    private let bus: AudioBus
    private var pump: DispatchSourceTimer?
    private let q = DispatchQueue(label: "audio-router.edge.shmin", qos: .userInteractive)
    private var pull = [Float](repeating: 0, count: 1024)
    private let lk = NSLock()
    private var got = 0
    private var ok = false

    init(shmName: String, bus: AudioBus) {
        self.bus = bus
        self.reader = ShmReader(name: shmName)
    }
    func start() {
        ok = reader.start()
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + .milliseconds(5),
                   repeating: .milliseconds(5), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let n = self.pull.withUnsafeMutableBufferPointer { self.reader.read(into: $0) }
            guard n > 0 else { return }
            self.pull.withUnsafeBufferPointer {
                self.bus.write(UnsafeBufferPointer(start: $0.baseAddress, count: n))
            }
            self.lk.lock(); self.got += n; self.lk.unlock()
        }
        t.resume()
        pump = t
    }
    func stop() { pump?.cancel(); pump = nil; reader.stop() }
    var diag: String {
        lk.lock(); defer { lk.unlock() }
        return "\(ok ? "open" : "NG") got=\(got)"
    }
}

// MARK: - OUT: bus → shm（/4ksp.voice か /babigoe.in）

@available(macOS 14.4, *)
final class ShmOutEdge: EdgeEngine {
    private let sender: ShmSender
    private let reader: AudioBus.Reader
    private var pump: DispatchSourceTimer?
    private let q = DispatchQueue(label: "audio-router.edge.shmout", qos: .userInteractive)
    private var pull = [Float](repeating: 0, count: 1024)

    init(shmName: String, bus: AudioBus) {
        self.sender = ShmSender(srcSampleRate: Double(AudioBus.rate), name: shmName)
        self.reader = bus.makeReader()
    }
    func start() {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + .milliseconds(5),
                   repeating: .milliseconds(5), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            // データ到来前でも shm を作成・所有（受信側が即 attach 可能に）。
            self.sender.open()
            let n = self.pull.withUnsafeMutableBufferPointer { self.reader.read(into: $0) }
            guard n > 0 else { return }
            self.pull.withUnsafeBufferPointer {
                self.sender.send(UnsafeBufferPointer(start: $0.baseAddress, count: n))
            }
        }
        t.resume()
        pump = t
    }
    func stop() { pump?.cancel(); pump = nil; sender.stop() }
    var diag: String { sender.statusLine }
}
