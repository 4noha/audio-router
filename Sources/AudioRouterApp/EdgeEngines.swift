import Foundation
import CoreAudio
import AVFoundation
import AudioRouterCore

/// 1 エッジの実行体。stop で停止、diag で毎秒の診断文字列。
@available(macOS 14.4, *)
protocol EdgeEngine: AnyObject {
    func stop()
    var diag: String { get }
    /// 累積処理フレーム数。前回値と比較してストリーム生存判定に使う。
    var frames: Int { get }
    /// 直近ウィンドウのピーク振幅（読むとリセット）。実信号判定に使う
    /// （無音バッファだけ流れている時は ♻ を回さないため）。
    var level: Float { get }
    /// 行に流す波形用：直近ブロックピーク履歴（古→新）。
    var waveform: [Float] { get }
    /// 直近 push からの小数位相 0..1（描画の滑らかサブピクセル送り用）。
    var waveFrac: Float { get }
}

/// スレッドセーフな直近ピーク履歴リング（行の波形表示用）。
/// 容量 = 表示バー数。push 頻度 × 容量 で時間窓が決まる。
/// `phase` は直近 push からの経過を 0→1 で返し、描画側がこの分だけ
/// 波形を左へサブピクセル送りすることで push 粒度より滑らかに流れる。
final class PeakRing: @unchecked Sendable {
    private let n: Int
    private let nominalRate: Double  // 初期 push レート(Hz)
    private var effRate: Double      // 実測 push レートの EMA（不規則追従）
    private var buf: [Float]
    private var idx = 0
    private var lastTime: CFAbsoluteTime = 0
    private let lk = NSLock()
    init(_ count: Int = 120, rate: Double = 100) {
        n = count
        nominalRate = rate > 0 ? rate : 100
        effRate = nominalRate
        buf = [Float](repeating: 0, count: count)
    }
    func push(_ v: Float) {
        lk.lock()
        let now = CFAbsoluteTimeGetCurrent()
        if lastTime != 0 {
            let dt = now - lastTime
            if dt > 0.002, dt < 0.5 {            // 異常間隔は無視
                effRate = effRate * 0.85 + (1.0 / dt) * 0.15
            }
        }
        buf[idx] = v; idx = (idx + 1) % n
        lastTime = now
        lk.unlock()
    }
    func snapshot() -> [Float] {
        lk.lock(); defer { lk.unlock() }
        return (0..<n).map { buf[(idx + $0) % n] }   // 古→新
    }
    /// 直近 push からの小数位相 0..1。**実測レート(EMA)** で割るので
    /// push が不規則でも次の push 直前に丁度 1 へ到達する。1 を越えて
    /// 先行 → 遅延 push で戻る（前後グラつき）が起きないよう [0,1] に
    /// クランプ（cadence が一定なら固まりもしない）。
    var phase: Double {
        lk.lock(); defer { lk.unlock() }
        guard lastTime != 0, effRate > 0 else { return 0 }
        return min(1, max(0, (CFAbsoluteTimeGetCurrent() - lastTime) * effRate))
    }
}

// MARK: - IN: アプリタップ → bus

@available(macOS 14.4, *)
final class TapInEdge: EdgeEngine {
    private let tap = ProcessTapEngine()
    private var rs: LinearResampler?
    private let bus: AudioBus
    private let lk = NSLock()
    private var _n = 0
    private var peak: Float = 0       // 直近バッファ（診断表示用）
    private var _lvl: Float = 0       // ウィンドウ最大（level 読取でリセット）
    private let wave = PeakRing()

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
            self.wave.push(pk)
            self.lk.lock()
            self._n += buf.count; self.peak = pk
            if pk > self._lvl { self._lvl = pk }
            self.lk.unlock()
        }
        try tap.startCapture(processObject: processObject, muteSource: muteSource)
    }
    func stop() { tap.stop() }
    var frames: Int { lk.lock(); defer { lk.unlock() }; return _n }
    var level: Float { lk.lock(); defer { lk.unlock() }; let v = _lvl; _lvl = 0; return v }
    var waveform: [Float] { wave.snapshot() }
    var waveFrac: Float { Float(wave.phase) }
    var diag: String {
        lk.lock(); defer { lk.unlock() }
        return "in=\(_n) lvl=\(String(format: "%.3f", peak))"
    }
}

// MARK: - IN: マイク → bus

@available(macOS 14.4, *)
final class MicInEdge: EdgeEngine {
    private var mic: MicCapture?
    private var rs: LinearResampler?
    private let bus: AudioBus
    private let lk = NSLock()
    private var _n = 0
    private var peak: Float = 0
    private var _lvl: Float = 0
    private let wave = PeakRing()

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
            self.wave.push(pk)
            self.lk.lock()
            self._n += buf.count; self.peak = pk
            if pk > self._lvl { self._lvl = pk }
            self.lk.unlock()
        }
        try cap.start()
        mic = cap
    }
    func stop() { mic?.stop(); mic = nil }
    var frames: Int { lk.lock(); defer { lk.unlock() }; return _n }
    var level: Float { lk.lock(); defer { lk.unlock() }; let v = _lvl; _lvl = 0; return v }
    var waveform: [Float] { wave.snapshot() }
    var waveFrac: Float { Float(wave.phase) }
    var diag: String {
        lk.lock(); defer { lk.unlock() }
        return "in=\(_n) lvl=\(String(format: "%.3f", peak))"
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
    private var _lvl: Float = 0
    private let wave = PeakRing()

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
            var pk: Float = 0
            for i in 0..<n { let a = abs(self.pull[i]); if a > pk { pk = a } }
            self.pull.withUnsafeBufferPointer {
                self.bus.write(UnsafeBufferPointer(start: $0.baseAddress, count: n))
            }
            self.wave.push(pk)
            self.lk.lock()
            self.got += n
            if pk > self._lvl { self._lvl = pk }
            self.lk.unlock()
        }
        t.resume()
        pump = t
    }
    func stop() { pump?.cancel(); pump = nil; reader.stop() }
    var frames: Int { lk.lock(); defer { lk.unlock() }; return got }
    var level: Float { lk.lock(); defer { lk.unlock() }; let v = _lvl; _lvl = 0; return v }
    var waveform: [Float] { wave.snapshot() }
    var waveFrac: Float { Float(wave.phase) }
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
    private let lk = NSLock()
    private var _lvl: Float = 0
    private let wave = PeakRing()

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
            var pk: Float = 0
            for i in 0..<n { let a = abs(self.pull[i]); if a > pk { pk = a } }
            self.pull.withUnsafeBufferPointer {
                self.sender.send(UnsafeBufferPointer(start: $0.baseAddress, count: n))
            }
            self.wave.push(pk)
            self.lk.lock()
            if pk > self._lvl { self._lvl = pk }
            self.lk.unlock()
        }
        t.resume()
        pump = t
    }
    func stop() { pump?.cancel(); pump = nil; sender.stop() }
    // 流量判定は「受信側が読み進めたか」(readIndex)＋実信号レベル。
    // 4ksplitter 停止で readIndex 凍結、無音で level 0 → どちらでも ♻ 停止。
    var frames: Int { sender.consumedFrames }
    /// 受信プロセスが生存しているか（kill(pid,0)）。false→sink に 🚫。
    var consumerAlive: Bool { sender.consumerAlive }
    var level: Float { lk.lock(); defer { lk.unlock() }; let v = _lvl; _lvl = 0; return v }
    var waveform: [Float] { wave.snapshot() }
    var waveFrac: Float { Float(wave.phase) }
    var diag: String { sender.statusLine }
}

// MARK: - OUT: bus → ファイル録音（WAV 16bit mono 48k）

@available(macOS 14.4, *)
final class RecorderOutEdge: EdgeEngine {
    private let reader: AudioBus.Reader
    private var file: AVAudioFile?
    private var pump: DispatchSourceTimer?
    private let q = DispatchQueue(label: "audio-router.edge.rec", qos: .utility)
    private var pull = [Float](repeating: 0, count: 4096)
    private let lk = NSLock()
    private var _n = 0
    private var _lvl: Float = 0
    // 波形 push は壁時計 ~25Hz(40ms) 一定 cadence（録音書込は 10ms のまま）。
    // 38 点 ÷ 25Hz ≒ 1.5 秒ぶん保持。バースト供給でも cadence を時間で
    // 固定するので、描画側の位相が 1 を越えず前後にグラつかない。
    private let wave = PeakRing(38, rate: 25)
    private var _wAcc: Float = 0          // 区間の最大ピーク（pump 専有）
    private var _wLast: CFAbsoluteTime = 0 // 直近 wave push の壁時計
    let url: URL

    init(bus: AudioBus) {
        self.reader = bus.makeReader()
        // 書込先: ~/Library/Application Support/AudioRouter/recordings/
        // （非サンドボックス・TCC プロンプト無しの安全な場所）。
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AudioRouter/recordings", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"
        self.url = dir.appendingPathComponent("rec-\(df.string(from: Date())).wav")
    }
    func start() {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(AudioBus.rate),
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        file = try? AVAudioFile(forWriting: url, settings: settings)
        let t = DispatchSource.makeTimerSource(queue: q)
        // 10ms ごとに 1 ピークを push（100Hz / 窓 ~1.1s）。短い周期で
        // 細かく送ることで波形がリアルタイムに流れて見える。
        t.schedule(deadline: .now() + .milliseconds(10),
                   repeating: .milliseconds(10), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in
            guard let self, let f = self.file else { return }
            let n = self.pull.withUnsafeMutableBufferPointer { self.reader.read(into: $0) }
            var pk: Float = 0
            if n > 0 {
                for i in 0..<n { let a = abs(self.pull[i]); if a > pk { pk = a } }
                if let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat,
                                              frameCapacity: AVAudioFrameCount(n)),
                   let ch = buf.floatChannelData {
                    buf.frameLength = AVAudioFrameCount(n)
                    self.pull.withUnsafeBufferPointer { src in
                        ch[0].update(from: src.baseAddress!, count: n)
                    }
                    try? f.write(from: buf)
                }
                self.lk.lock()
                self._n += n
                if pk > self._lvl { self._lvl = pk }
                self.lk.unlock()
            }
            // 波形 push は壁時計 40ms 基準で一定 cadence（読めた回数で
            // なく時間で叩く）。アンダーラン中も無音(0)を流して止めない。
            // cadence が一定なので描画側の位相が 1 を越えず前後しない。
            self._wAcc = max(self._wAcc, pk)
            let now = CFAbsoluteTimeGetCurrent()
            if self._wLast == 0 { self._wLast = now }
            if now - self._wLast >= 0.040 {
                self.wave.push(self._wAcc)
                self._wAcc = 0
                self._wLast = now
            }
        }
        t.resume()
        pump = t
    }
    func stop() { pump?.cancel(); pump = nil; file = nil }   // file=nil で close/flush
    var frames: Int { lk.lock(); defer { lk.unlock() }; return _n }
    var level: Float { lk.lock(); defer { lk.unlock() }; let v = _lvl; _lvl = 0; return v }
    var waveform: [Float] { wave.snapshot() }
    var waveFrac: Float { Float(wave.phase) }
    var diag: String {
        lk.lock(); let n = _n; lk.unlock()
        return "rec \(n)f → \(url.lastPathComponent)"
    }
}
