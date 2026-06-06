import Foundation
import Network

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// audio-router 側の UDP 受信ハブ。
/// `_4noha-audio._udp` を Bonjour publish し、UDP で来るパケットを slot 別に
/// jitter buffer → デコード → mono 48k Float32 リングへ書き込む。Android
/// 側がここに接続してマイク音を流す。
///
/// 1 インスタンスで slot 1..4 を同時にホストする。送り元（IP+ポート）が変
/// わってもパケット header.slot で振り分けるので Android の NAT 変動に強い。
///
/// 戻し（Mac → Android）の送信先 endpoint は、slot ごとに「最後に受信した
/// パケットの源」を覚えておく。`NetAudioBroadcaster` がそれを参照して送る。
@available(macOS 14.4, *)
public final class NetAudioServer: @unchecked Sendable {
    public static let serviceType = "_4noha-audio._udp"
    public static let defaultPort: UInt16 = 47391

    public enum ServerError: Error {
        case listenerCreateFailed(String)
        case alreadyStarted
    }

    /// 受信 slot 数。1..4。
    public let slotCount: Int

    /// 各 slot の音声出力（mono 48k Float32）。fan-out 用に Reader を作る。
    public let slotBuses: [AudioBus]

    /// 各 slot の Opus デコーダ（lazy）。
    private var slotDecoders: [Int: OpusMonoDecoder] = [:]

    /// 各 slot のジッタバッファ状態。
    private final class SlotState {
        var expectedSeq: UInt32?
        // seq → (codec, payload)。受信時に積み、pop タイマで取り出す。
        var buffer: [UInt32: (NetAudio.Codec, Data)] = [:]
        // 最終受信パケット送信元（戻し送信用 endpoint）。
        var lastPeer: NWEndpoint?
        var lastPeerAt: Date?
        // 戻し送信用に **listener 側 NWConnection** を保持。新規 NWConnection
        // を作って送ると ephemeral 送信元 port になり、Android 側 connect 済
        // socket のソース filter に弾かれる。listener conn 経由なら送信元
        // は listener bind port 固定で問題ない。
        var lastConn: NWConnection?
        // HELLO payload 由来の Android 端末名。複数台識別用に Mac UI へ
        // 反映する。audio パケットには名前は乗らないので、初回 HELLO や
        // 後続 HELLO (keep-alive) で更新される。
        var deviceName: String = ""
        // HELLO payload v2 から: アプリのバージョン文字列 (デバッグ用)。
        var appVersion: String = ""
        var bytesIn: Int64 = 0
        var packetsIn: Int64 = 0
        var packetsDropped: Int64 = 0
        var packetsLost: Int64 = 0
    }
    private var states: [Int: SlotState] = [:]
    private let stateLock = NSLock()
    // 端末名 → 割当 slot のマップ。**端末名で行を管理する**ため、Android
    // 側が slot を選ぶのではなく Mac 側が初見の端末に空き slot を動的割当
    // して hello-ack の slot フィールドで通知する。slotByName で過去に
    // 割当てた slot を再現できるので、Android の再接続でも同じ slot が
    // 維持される。
    private var slotByName: [String: Int] = [:]

    /// 出力 cadence（jitter buffer pop 間隔）。20ms 固定。Android 側も
    /// frame=960 (20ms) で encode する前提。
    private let popIntervalMs: Int = 20
    /// pop 開始までに溜める目標フレーム数（≈ 60ms）。少なすぎると
    /// ロス耐性なし、多すぎると遅延悪化。
    private let targetDepth: Int = 3
    /// バッファ上限（暴走防止）。
    private let maxBuffer: Int = 16

    /// HELLO 受信時のコールバック。slot 番号 / peer endpoint / Android
    /// 端末名 (HELLO payload 由来、UTF-8) が渡る。同 slot で初めて HELLO
    /// が来たとき、または peer endpoint / 名前が変わったときに発火する。
    /// RouterController が「自動で行追加」「既存行の名前更新」等を行う。
    /// 呼出スレッドはリスナキュー（非 main）。
    public var onSlotPaired: ((Int, NWEndpoint, String) -> Void)?

    private let listenerQ = DispatchQueue(label: "audio-router.net.listener",
                                          qos: .userInitiated)
    /// slot → 端末専用 NWListener とその bind port。HELLO で slot 割当時に
    /// オープン (既存ならそのまま再利用)。hello-ack で port をアプリに通知する。
    /// 複数端末を独立ポートで扱うことで衝突や状態漏れを完全に分離する。
    private var perSlotListeners: [Int: NWListener] = [:]
    private var perSlotPort: [Int: UInt16] = [:]
    private let popQ = DispatchQueue(label: "audio-router.net.pop",
                                     qos: .userInteractive)
    private var listener: NWListener?
    private var popTimer: DispatchSourceTimer?
    /// 接続(送信元) ごとの NWConnection。NAT で変わると別 entry になる。
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var connLock = NSLock()
    private var isRunning = false

    public init(slotCount: Int = 4) {
        precondition(slotCount >= 1 && slotCount <= 4)
        self.slotCount = slotCount
        var buses: [AudioBus] = []
        for _ in 0..<slotCount {
            buses.append(AudioBus(seconds: 1.0))
        }
        self.slotBuses = buses
        for s in 1...slotCount {
            states[s] = SlotState()
        }
    }

    deinit { stop() }

    /// 待受ポート（実際にバインドされた値）。Bonjour で公開される値と一致。
    public private(set) var boundPort: UInt16 = 0

    /// 起動。Bonjour publish + UDP listen 開始。
    public func start(port: UInt16 = NetAudioServer.defaultPort) throws {
        if isRunning { throw ServerError.alreadyStarted }
        // NWParameters: UDP。MTU 内 1 パケット 1 フレーム前提。
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        let endpointPort = NWEndpoint.Port(rawValue: port) ?? .any
        let l: NWListener
        do {
            l = try NWListener(using: params, on: endpointPort)
        } catch {
            throw ServerError.listenerCreateFailed(error.localizedDescription)
        }
        // Bonjour publish。複数 slot を 1 service で扱う。
        var txt = NWTXTRecord()
        txt["ver"] = "1"
        txt["slots"] = String(slotCount)
        txt["fmt"] = "f32-mono-48k"
        l.service = NWListener.Service(
            name: "audio-router-\(Host.current().localizedName ?? "mac")",
            type: Self.serviceType,
            domain: "local",
            txtRecord: txt)
        l.newConnectionHandler = { [weak self] conn in
            self?.handleNewConnection(conn)
        }
        l.stateUpdateHandler = { state in
            switch state {
            case .ready:
                break
            case .failed(let e):
                NSLog("NetAudioServer listener failed: \(e)")
            default: break
            }
        }
        l.start(queue: listenerQ)
        listener = l
        // start() 直後だと port がまだ未確定なことがあるので少し待ってから捕捉。
        listenerQ.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            self?.boundPort = l.port?.rawValue ?? port
        }
        startPopTimer()
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        popTimer?.cancel(); popTimer = nil
        listener?.cancel(); listener = nil
        for (_, l) in perSlotListeners { l.cancel() }
        perSlotListeners.removeAll()
        perSlotPort.removeAll()
        connLock.lock()
        for (_, c) in connections { c.cancel() }
        connections.removeAll()
        connLock.unlock()
    }

    /// slot 専用 NWListener を必要時に開く。port は 47391 + slot で固定割当
    /// (port 衝突した場合は 0 を返し、アプリは discovery port にフォールバック)。
    /// 返り値は bind 成功した port (失敗時 0)。
    private func ensurePerSlotListener(slot: Int) -> UInt16 {
        if let p = perSlotPort[slot] { return p }
        let portNum: UInt16 = Self.defaultPort + UInt16(slot)
        guard let nwPort = NWEndpoint.Port(rawValue: portNum) else { return 0 }
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        let l: NWListener
        do { l = try NWListener(using: params, on: nwPort) } catch {
            NSLog("[NetAudioServer] per-slot listener port=\(portNum) failed: \(error)")
            return 0
        }
        l.newConnectionHandler = { [weak self] conn in
            self?.handleNewConnection(conn)
        }
        l.stateUpdateHandler = { state in
            if case .failed(let e) = state {
                NSLog("[NetAudioServer] per-slot port=\(portNum) failed: \(e)")
            }
        }
        l.start(queue: listenerQ)
        perSlotListeners[slot] = l
        perSlotPort[slot] = portNum
        return portNum
    }

    // MARK: 接続ハンドル

    private func handleNewConnection(_ conn: NWConnection) {
        let key = ObjectIdentifier(conn)
        connLock.lock()
        connections[key] = conn
        connLock.unlock()
        conn.stateUpdateHandler = { [weak self] st in
            switch st {
            case .cancelled, .failed:
                self?.connLock.lock()
                self?.connections[key] = nil
                self?.connLock.unlock()
            default: break
            }
        }
        conn.start(queue: listenerQ)
        receiveLoop(conn)
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, err in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.handleDatagram(data, from: conn.endpoint, on: conn)
            }
            if err == nil {
                self.receiveLoop(conn)
            }
        }
    }

    private func handleDatagram(_ data: Data, from peer: NWEndpoint, on conn: NWConnection) {
        guard let (h, payload) = NetAudio.decode(data) else {
            NSLog("[NetAudioServer] dropped malformed packet (\(data.count)b) from \(peer)")
            return
        }
        let slot = Int(h.slot)
        NSLog("[NetAudioServer] rx type=\(h.type) slot=\(slot) codec=\(h.codec) seq=\(h.seq) plen=\(h.payloadLen) from=\(peer)")
        switch h.type {
        case .hello:
            // payload format (デバッグ向け拡張、後方互換):
            //   "deviceName"                  (旧)
            //   "deviceName\0appVersion"      (新: null 区切り、後ろに app バージョン)
            // null が無い旧アプリは全部を name として扱う。
            var name = "Android"
            var appVersion = ""
            if !payload.isEmpty {
                let parts = payload.split(separator: 0x00, maxSplits: 1,
                                           omittingEmptySubsequences: false)
                if let nameData = parts.first,
                   let n = String(data: Data(nameData), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespaces),
                   !n.isEmpty { name = n }
                if parts.count > 1,
                   let v = String(data: Data(parts[1]), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespaces) {
                    appVersion = v
                }
            }
            // 端末名から slot を引く or 新規割当（空き 1..N の若い方）。
            // 既存名は再接続でも同じ slot を維持。
            stateLock.lock()
            var assigned: Int
            if let s = slotByName[name] {
                assigned = s
            } else {
                let usedSlots = Set(slotByName.values)
                var picked = 0
                for i in 1...slotCount where !usedSlots.contains(i) {
                    picked = i; break
                }
                if picked == 0 {
                    // 満員: 一番古い slot を奪う（lastPeerAt 最古）。
                    let oldest = (1...slotCount)
                        .min { (states[$0]?.lastPeerAt ?? .distantPast)
                             < (states[$1]?.lastPeerAt ?? .distantPast) }
                    picked = oldest ?? 1
                    // 旧 owner 名を slotByName から外す
                    if let oldName = nameForSlot(picked) {
                        slotByName.removeValue(forKey: oldName)
                    }
                }
                slotByName[name] = picked
                assigned = picked
            }
            var notify = false
            if let st = states[assigned] {
                let samePeer: Bool
                if let last = st.lastPeer { samePeer = endpointMatches(last, peer) }
                else { samePeer = false }
                let sameName = (st.deviceName == name)
                notify = !samePeer || !sameName
                st.lastPeer = peer
                st.lastPeerAt = Date()
                st.lastConn = conn
                st.deviceName = name
                if !appVersion.isEmpty { st.appVersion = appVersion }
            }
            stateLock.unlock()
            // 端末専用 listener を確保 (port = 47391 + slot)。
            let assignedPort = ensurePerSlotListener(slot: assigned)
            // hello-ack: payload に [port BE u16][Mac名 UTF-8] を入れる。
            // アプリはこの port に切替えて以降の send/recv を行う。
            sendHelloAck(on: conn, slot: UInt8(assigned), assignedPort: assignedPort)
            if notify { onSlotPaired?(assigned, peer, name) }
        case .bye:
            let s = max(1, min(slotCount, slot))
            stateLock.lock()
            states[s]?.lastPeer = nil
            stateLock.unlock()
        case .ping:
            // エコー: 受信した payload を含めて ping を返す（listener の
            // 既存 conn 経由＝送信元は 47391 固定）。
            sendPong(on: conn, slot: h.slot, payload: payload, seq: h.seq)
        case .audio:
            guard slot >= 1 && slot <= slotCount else { return }
            var firstAudioOrChanged = false
            stateLock.lock()
            guard let st = states[slot] else { stateLock.unlock(); return }
            // Mac 再起動などで HELLO を取り逃しても、最初の audio パケットで
            // 自動的にペアリング扱いにする（呼出側で auto-add row）。
            let sameAudioPeer: Bool
            if let last = st.lastPeer { sameAudioPeer = endpointMatches(last, peer) }
            else { sameAudioPeer = false }
            firstAudioOrChanged = !sameAudioPeer
            st.lastPeer = peer
            st.lastPeerAt = Date()
            st.lastConn = conn          // 戻し送信用に listener conn を更新
            st.bytesIn &+= Int64(data.count)
            st.packetsIn &+= 1
            // seq 並び替え用バッファへ。
            if st.expectedSeq == nil {
                st.expectedSeq = h.seq
            }
            if let exp = st.expectedSeq {
                // 大きく未来側 (>50) なら reseed。
                let diff = h.seq &- exp
                if diff > 50 && diff < UInt32.max - 50 {
                    st.expectedSeq = h.seq
                    st.buffer.removeAll()
                }
                let backDiff = exp &- h.seq
                if backDiff > 0 && backDiff < 0x80000000 {
                    // 既に再生済みの古いパケット。drop。
                    st.packetsDropped &+= 1
                    stateLock.unlock()
                    return
                }
            }
            // バッファ上限を超えていたら最古を捨てる。
            if st.buffer.count >= maxBuffer {
                if let oldest = st.buffer.keys.min() {
                    st.buffer.removeValue(forKey: oldest)
                    st.packetsDropped &+= 1
                }
            }
            st.buffer[h.seq] = (h.codec, payload)
            stateLock.unlock()
            // HELLO 経由のペアリングを取り逃した場合の救済。最初の audio で
            // も onSlotPaired を発火し、Mac 側 RouterController が auto-add
            // 行を作る（既存行があれば no-op）。name は既知のもの、無ければ
            // 仮 "Android" を渡す。HELLO が後から来たら更新される。
            if firstAudioOrChanged {
                stateLock.lock()
                let n = states[slot]?.deviceName.nilIfEmpty ?? "Android"
                stateLock.unlock()
                onSlotPaired?(slot, peer, n)
            }
        }
    }

    /// HELLO の確認応答。listener の既存 NWConnection で送り返す。
    /// payload 構造: [port BE u16][Mac 名 UTF-8]。アプリは port を読んで
    /// 以降の通信を **その port** に向ける。port=0 ならアプリは discovery
    /// port (= 受信元 port) 維持。
    private func sendHelloAck(on conn: NWConnection, slot: UInt8, assignedPort: UInt16) {
        let nameStr = Host.current().localizedName ?? "Mac"
        var body = Data()
        body.append(UInt8((assignedPort >> 8) & 0xff))
        body.append(UInt8(assignedPort & 0xff))
        body.append(contentsOf: nameStr.utf8)
        let pkt = NetAudio.encode(NetAudio.Header(
            type: .hello, slot: slot, codec: .pcm16le,
            seq: 0, tsUs: NetAudio.nowMicros(),
            payloadLen: UInt16(body.count)), payload: body)
        conn.send(content: pkt, completion: .contentProcessed { _ in })
    }

    /// slotByName から逆引き（slot → 端末名）。stateLock 保持で呼出。
    private func nameForSlot(_ slot: Int) -> String? {
        for (n, s) in slotByName where s == slot { return n }
        return nil
    }

    /// hostPort で同一比較、それ以外は文字列フォールバック。
    private func endpointMatches(_ a: NWEndpoint, _ b: NWEndpoint) -> Bool {
        if case .hostPort(let ha, let pa) = a,
           case .hostPort(let hb, let pb) = b {
            return "\(ha)" == "\(hb)" && pa == pb
        }
        return "\(a)" == "\(b)"
    }

    private func sendPong(on conn: NWConnection, slot: UInt8, payload: Data, seq: UInt32) {
        let nameStr = Host.current().localizedName ?? "Mac"
        let body = Data(nameStr.utf8)
        _ = payload
        let pong = NetAudio.encode(NetAudio.Header(
            type: .ping, slot: slot, codec: .pcm16le,
            seq: seq, tsUs: NetAudio.nowMicros(),
            payloadLen: UInt16(body.count)), payload: body)
        let peer = "\(conn.endpoint)"
        let st = "\(conn.state)"
        conn.send(content: pong, completion: .contentProcessed { err in
            if let err = err {
                NSLog("[NetAudioServer] PONG send err=\(err) peer=\(peer) state=\(st)")
            } else {
                NSLog("[NetAudioServer] PONG sent (\(pong.count)b) peer=\(peer)")
            }
        })
    }

    /// 戻し送信用に slot ごとの最終受信ピアを返す（参照／診断表示用）。
    public func peer(forSlot slot: Int) -> NWEndpoint? {
        stateLock.lock(); defer { stateLock.unlock() }
        guard let st = states[slot] else { return nil }
        return st.lastPeer
    }

    /// Mac→Android の戻し送信。listener 既存 NWConnection 経由で送るので
    /// 送信元 port が listener の bind port (= 47391) になり、Android 側で
    /// connect 済 socket のソース filter に弾かれない。slot ごとに最後の
    /// conn を保存しておくのが SlotState.lastConn。戻り値は送信できたか。
    @discardableResult
    public func send(toSlot slot: Int, data: Data) -> Bool {
        stateLock.lock()
        let conn = states[slot]?.lastConn
        stateLock.unlock()
        guard let conn = conn else { return false }
        conn.send(content: data, completion: .contentProcessed { _ in })
        return true
    }

    /// ピアが直近 N 秒以内に生存しているか。
    public func peerAlive(forSlot slot: Int, within seconds: TimeInterval = 5) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard let st = states[slot], let at = st.lastPeerAt else { return false }
        return Date().timeIntervalSince(at) <= seconds
    }

    /// 簡易診断: 1 slot のカウンタを取得。
    public struct SlotDiag {
        public var packetsIn: Int64
        public var bytesIn: Int64
        public var packetsDropped: Int64
        public var packetsLost: Int64
        public var bufferDepth: Int
        public var peerHost: String?
        public var deviceName: String
        public var appVersion: String
    }
    public func diag(slot: Int) -> SlotDiag {
        stateLock.lock(); defer { stateLock.unlock() }
        guard let st = states[slot] else {
            return SlotDiag(packetsIn: 0, bytesIn: 0, packetsDropped: 0,
                            packetsLost: 0, bufferDepth: 0, peerHost: nil,
                            deviceName: "", appVersion: "")
        }
        var host: String?
        if case .hostPort(let h, _) = st.lastPeer { host = "\(h)" }
        return SlotDiag(packetsIn: st.packetsIn, bytesIn: st.bytesIn,
                        packetsDropped: st.packetsDropped,
                        packetsLost: st.packetsLost,
                        bufferDepth: st.buffer.count,
                        peerHost: host,
                        deviceName: st.deviceName,
                        appVersion: st.appVersion)
    }

    // MARK: jitter buffer pop

    private func startPopTimer() {
        let t = DispatchSource.makeTimerSource(queue: popQ)
        t.schedule(deadline: .now() + .milliseconds(popIntervalMs),
                   repeating: .milliseconds(popIntervalMs),
                   leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.popTick() }
        t.resume()
        popTimer = t
    }

    private func popTick() {
        for slot in 1...slotCount {
            popOne(slot: slot)
        }
    }

    /// 1 slot のジッタバッファから 1 フレーム取り出してリングへ書く。
    /// バッファに無いが targetDepth 以上溜まる気配が無く expectedSeq が
    /// 来ないなら PLC (silence) でスキップ。
    private func popOne(slot: Int) {
        // states 操作は短時間でロック解放。デコードはロック外で実施。
        var picked: (UInt32, NetAudio.Codec, Data)?
        var doPLC = false
        stateLock.lock()
        guard let st = states[slot] else { stateLock.unlock(); return }
        if let exp = st.expectedSeq {
            if let item = st.buffer.removeValue(forKey: exp) {
                picked = (exp, item.0, item.1)
                st.expectedSeq = exp &+ 1
            } else if st.buffer.count >= targetDepth {
                // 当該 seq が来ない＝ロスト。PLC でスキップ。
                st.expectedSeq = exp &+ 1
                st.packetsLost &+= 1
                doPLC = true
            } else {
                // 待機（pop しない）。
            }
        }
        stateLock.unlock()

        if let (_, codec, data) = picked {
            decodeAndPush(slot: slot, codec: codec, data: data)
        } else if doPLC {
            decodeAndPush(slot: slot, codec: .opus, data: Data())
        }
    }

    /// payload (codec) を mono 48k Float32 に変換し slot bus に write。
    private func decodeAndPush(slot: Int, codec: NetAudio.Codec, data: Data) {
        switch codec {
        case .pcm16le:
            // 16-bit LE PCM → Float32 [-1, 1]。
            let count = data.count / 2
            guard count > 0 else { return }
            var out = [Float](repeating: 0, count: count)
            data.withUnsafeBytes { rb in
                let p = rb.bindMemory(to: Int16.self)
                for i in 0..<count {
                    out[i] = Float(Int16(littleEndian: p[i])) / 32768.0
                }
            }
            out.withUnsafeBufferPointer { bp in
                slotBuses[slot - 1].write(UnsafeBufferPointer(
                    start: bp.baseAddress, count: count))
            }
        case .opus:
            do {
                let dec = try getOpusDecoder(slot: slot)
                let pcm: [Float]
                if data.isEmpty {
                    // PLC
                    pcm = try dec.decode(nil, expectedFrameSize: 960)
                } else {
                    pcm = try dec.decode(data)
                }
                if !pcm.isEmpty {
                    pcm.withUnsafeBufferPointer { bp in
                        slotBuses[slot - 1].write(UnsafeBufferPointer(
                            start: bp.baseAddress, count: pcm.count))
                    }
                }
            } catch {
                // デコード失敗は単に drop（次フレームへ）。
            }
        }
    }

    /// slot 用 Opus デコーダ（lazy 生成）。
    private func getOpusDecoder(slot: Int) throws -> OpusMonoDecoder {
        stateLock.lock(); defer { stateLock.unlock() }
        if let d = slotDecoders[slot] { return d }
        let d = try OpusMonoDecoder()
        slotDecoders[slot] = d
        return d
    }
}
