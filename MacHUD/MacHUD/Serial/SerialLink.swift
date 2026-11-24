import AppKit
import Darwin

/// Owns the USB serial connection to the ESP32 HUD.
///
/// * Discovers the device by USB vendor ID (Espressif 0x303A) + HELLO handshake.
/// * Keeps at most one frame in flight; newer frames replace the pending one.
/// * Resyncs on ACK timeout, reconnects on unplug/replug and after sleep/wake.
/// * Never opens the port exclusively; `releasePort()` closes it so other tools
///   (Arduino IDE / esptool) can use it.
///
/// All state is confined to `queue`. Public methods are safe to call from any thread.
final class SerialLink: @unchecked Sendable {
    enum Status: Equatable {
        case notFound
        case searching(port: String?)
        case connected(port: String, firmware: String)
        case released
    }

    /// Called on the main thread.
    var onStatusChange: ((Status) -> Void)?

    static let espressifVID = 0x303A
    static let deviceID = "ESP32-HUD"

    private let queue = DispatchQueue(label: "SerialLink", qos: .userInitiated)
    private let scanner = SerialPortScanner(vendorID: SerialLink.espressifVID)

    // Timing (seconds)
    private let handshakeTimeout: TimeInterval = 1.0
    private let ackTimeout: TimeInterval = 1.5
    private let pingInterval: TimeInterval = 3.0
    private let rescanInterval: TimeInterval = 2.0
    private let maxResyncAttempts = 3

    // Connection state (queue only)
    private enum Phase {
        case idle
        case handshaking(candidates: [String], deadline: Date)
        case connected
        case resyncing(attempt: Int, deadline: Date)
    }

    private enum InFlightKind { case frame, command, ping }

    private var phase: Phase = .idle
    private var fd: Int32 = -1
    private var portPath: String?
    private var readSource: DispatchSourceRead?
    private var tickTimer: DispatchSourceTimer?
    private var parser = PacketParser()
    private var seq: UInt8 = 0
    private var handshakeSeq: UInt8 = 0
    private var inFlight: (seq: UInt8, kind: InFlightKind, sentAt: Date)?
    private var lastTx = Date.distantPast
    private var nextScan = Date.distantPast
    private var released = false
    private var asleep = false
    private var status: Status = .notFound

    // Desired device state (queue only)
    private var displayOn = true
    private var displayStateDirty = true
    private var latestFrame: Data?
    private var frameDirty = false
    private var badCRCResends = 0

    private var workspaceObservers: [NSObjectProtocol] = []

    // MARK: - Public API

    func start() {
        queue.async { [self] in
            scanner.startMonitoring(queue: queue) { [weak self] in self?.devicesChanged() }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(100))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            tickTimer = t
        }

        let wnc = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(wnc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.asleep = true; self?.disconnect() }
        })
        workspaceObservers.append(wnc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async {
                guard let self else { return }
                self.asleep = false
                self.disconnect()                      // the old fd is usually stale after wake
                self.nextScan = Date().addingTimeInterval(1)  // give USB a moment to re-enumerate
            }
        })
    }

    /// Set the newest frame. It is sent once the previous one has been ACKed.
    func submitFrame(_ jpeg: Data) {
        queue.async { [self] in
            latestFrame = jpeg
            frameDirty = true
            badCRCResends = 0
            pump()
        }
    }

    func setDisplayOn(_ on: Bool) {
        queue.async { [self] in
            guard on != displayOn else { return }
            displayOn = on
            displayStateDirty = true
            if on { frameDirty = latestFrame != nil }
            pump()
        }
    }

    /// Close the port and stop reconnecting (e.g. to flash firmware).
    func releasePort() {
        queue.async { [self] in
            released = true
            disconnect()
            setStatus(.released)
        }
    }

    func reconnect() {
        queue.async { [self] in
            released = false
            disconnect()
            nextScan = .distantPast
            tick()
        }
    }

    // MARK: - Discovery

    private func devicesChanged() {
        if let path = portPath, !FileManager.default.fileExists(atPath: path) {
            disconnect()
        }
        nextScan = .distantPast
    }

    private func tick() {
        let now = Date()
        guard !released, !asleep else { return }

        switch phase {
        case .idle:
            guard now >= nextScan else { return }
            nextScan = now.addingTimeInterval(rescanInterval)
            let ports = scanner.matchingPorts()
            if ports.isEmpty {
                setStatus(.notFound)
            } else {
                tryNextCandidate(ports)
            }

        case .handshaking(let candidates, let deadline):
            if now > deadline {
                closePort()
                tryNextCandidate(candidates)
            }

        case .resyncing(let attempt, let deadline):
            if now > deadline {
                if attempt >= maxResyncAttempts {
                    disconnect()
                } else {
                    startResync(attempt: attempt + 1)
                }
            }

        case .connected:
            if let f = inFlight {
                if now.timeIntervalSince(f.sentAt) > ackTimeout { startResync(attempt: 1) }
            } else {
                pump()
            }
        }
    }

    private func tryNextCandidate(_ candidates: [String]) {
        var remaining = candidates
        while !remaining.isEmpty {
            let path = remaining.removeFirst()
            setStatus(.searching(port: displayName(path)))
            guard openPort(path) else { continue }
            handshakeSeq = nextSeq()
            parser.reset()
            phase = .handshaking(candidates: remaining, deadline: Date().addingTimeInterval(handshakeTimeout))
            if !send(.hello, seq: handshakeSeq) { closePort(); continue }
            return
        }
        phase = .idle   // all candidates failed; status stays "searching" until the next scan
    }

    private func startResync(attempt: Int) {
        inFlight = nil
        parser.reset()
        if fd >= 0 { tcflush(fd, TCIOFLUSH) }
        handshakeSeq = nextSeq()
        phase = .resyncing(attempt: attempt, deadline: Date().addingTimeInterval(handshakeTimeout))
        if !send(.hello, seq: handshakeSeq) { disconnect() }
    }

    private func didHandshake(firmware fw: String) {
        let wasConnected: Bool
        if case .connected = phase { wasConnected = true } else { wasConnected = false }
        phase = .connected
        inFlight = nil
        // The device may have rebooted: re-send display state and the newest frame.
        displayStateDirty = true
        frameDirty = latestFrame != nil
        if !wasConnected, let path = portPath {
            setStatus(.connected(port: displayName(path), firmware: fw))
        }
        pump()
    }

    // MARK: - Sending

    /// Sends whatever is next, if nothing is in flight.
    private func pump() {
        guard case .connected = phase, inFlight == nil else { return }
        let now = Date()
        if displayStateDirty {
            displayStateDirty = false
            sendTracked(displayOn ? .displayOn : .displayOff, kind: .command)
        } else if displayOn, frameDirty, let frame = latestFrame {
            frameDirty = false
            sendTracked(.frame, payload: frame, kind: .frame)
        } else if now.timeIntervalSince(lastTx) > pingInterval {
            sendTracked(.ping, kind: .ping)
        }
    }

    private func sendTracked(_ type: MsgType, payload: Data = Data(), kind: InFlightKind) {
        let s = nextSeq()
        inFlight = (s, kind, Date())
        if !send(type, seq: s, payload: payload) { disconnect() }
    }

    private func nextSeq() -> UInt8 {
        seq &+= 1
        return seq
    }

    @discardableResult
    private func send(_ type: MsgType, seq: UInt8, payload: Data = Data()) -> Bool {
        guard fd >= 0 else { return false }
        let bytes = Packet(type: type.rawValue, seq: seq, payload: payload).encoded()
        lastTx = Date()
        return bytes.withUnsafeBytes { raw -> Bool in
            guard var p = raw.baseAddress else { return true }
            var left = raw.count
            let deadline = Date().addingTimeInterval(2)
            while left > 0 {
                let n = Darwin.write(fd, p, left)
                if n > 0 {
                    p += n
                    left -= n
                } else if n < 0 && (errno == EAGAIN || errno == EINTR) {
                    if Date() > deadline { return false }
                    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&pfd, 1, 200)
                } else {
                    return false
                }
            }
            return true
        }
    }

    // MARK: - Receiving

    private func handleReadable() {
        guard fd >= 0 else { return }
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                let packets = buf.withUnsafeBytes { parser.feed(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
                packets.forEach(handle)
                if fd < 0 { return }
            } else if n < 0 && errno == EAGAIN {
                return
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                // EOF or ENXIO: device went away.
                disconnect()
                nextScan = Date().addingTimeInterval(0.5)
                return
            }
        }
    }

    private func handle(_ packet: Packet) {
        switch MsgType(rawValue: packet.type) {
        case .helloReply:
            let info = parseKV(packet.payload)
            guard info["id"] == Self.deviceID, packet.seq == handshakeSeq else { return }
            switch phase {
            case .handshaking, .resyncing:
                didHandshake(firmware: info["fw"] ?? "?")
            default: break
            }

        case .pong:
            if let f = inFlight, f.kind == .ping, f.seq == packet.seq { inFlight = nil; pump() }

        case .ack:
            guard packet.payload.count >= 2 else { return }
            let ackSeq = packet.payload[packet.payload.startIndex]
            let status = AckStatus(rawValue: packet.payload[packet.payload.startIndex + 1])
            guard let f = inFlight, f.seq == ackSeq else { return }
            inFlight = nil
            if status == .badCRC {
                if f.kind == .frame, badCRCResends < 1 { badCRCResends += 1; frameDirty = true }
                if f.kind == .command { displayStateDirty = true }
            } else if status == .decodeFailed {
                NSLog("MacHUD: device failed to decode frame")
            }
            pump()

        default:
            break
        }
    }

    private func parseKV(_ data: Data) -> [String: String] {
        var out = [String: String]()
        for pair in String(decoding: data, as: UTF8.self).split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }

    // MARK: - Port management

    private func openPort(_ path: String) -> Bool {
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return false }

        var tio = termios()
        if tcgetattr(fd, &tio) != 0 { Darwin.close(fd); return false }
        cfmakeraw(&tio)
        tio.c_cflag |= tcflag_t(CLOCAL | CREAD)
        cfsetspeed(&tio, speed_t(B115200))
        // VMIN/VTIME are irrelevant in non-blocking mode.
        if tcsetattr(fd, TCSANOW, &tio) != 0 { Darwin.close(fd); return false }

        // DTR on, RTS off. On the ESP32-S3 USB Serial/JTAG, RTS high while DTR is low resets the chip.
        var bits: Int32 = 0x002 // TIOCM_DTR
        let TIOCMSET: UInt = 0x8004_746D // _IOW('t', 109, int)
        _ = withUnsafeMutablePointer(to: &bits) { ioctl(fd, TIOCMSET, $0) }
        tcflush(fd, TCIOFLUSH)

        self.fd = fd
        portPath = path
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.handleReadable() }
        src.setCancelHandler { Darwin.close(fd) }
        src.resume()
        readSource = src
        return true
    }

    private func closePort() {
        if let src = readSource {
            src.cancel()      // the cancel handler closes the fd
            readSource = nil
        } else if fd >= 0 {
            Darwin.close(fd)
        }
        fd = -1
        portPath = nil
        inFlight = nil
        parser.reset()
    }

    /// Close and go back to discovery.
    private func disconnect() {
        closePort()
        phase = .idle
        if !released { setStatus(.searching(port: nil)) }
        nextScan = Date().addingTimeInterval(rescanInterval / 2)
    }

    private func setStatus(_ s: Status) {
        guard s != status else { return }
        status = s
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onStatusChange?(s)
        }
    }

    private func displayName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
