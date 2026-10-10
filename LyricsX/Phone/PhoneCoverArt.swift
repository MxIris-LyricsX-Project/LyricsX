import AppKit
import IOBluetooth

protocol PhoneArtworkTransport: AnyObject {
    var onReady: (() -> Void)? { get set }
    var onImage: ((String, Data) -> Void)? { get set }
    var onState: ((PhoneArtworkState) -> Void)? { get set }
    func connect(address: String)
    func connect(address: String, psm: UInt16?)
    func fetch(handle: String)
    func restartSession()
    func disconnect()
}
extension PhoneArtworkTransport {
    func connect(address: String, psm: UInt16?) { connect(address: address) }
    func restartSession() { disconnect() }
}
enum PhoneArtworkState: String, Codable { case unavailable, connecting, ready, loading, loaded }

/// Only the AVRCP BIP GetLinkedThumbnail feature: a separate, optional image channel.
/// This code only closes its own image channel; peer-side behavior is device dependent.
final class NativePhoneCoverArt: NSObject, PhoneArtworkTransport, IOBluetoothL2CAPChannelDelegate {
    var onReady: (() -> Void)?
    var onImage: ((String, Data) -> Void)?
    var onState: ((PhoneArtworkState) -> Void)?
    private var attemptedAddresses = Set<String>()
    private let enabled: Bool
    // Opt in only inside the isolated cover worker: delayed native callbacks can
    // enter synchronous waits on that process's main queue. The UI supervisor
    // enforces a timeout; no alternate cover source is used.
    init(enabled: Bool = false) {
        if enabled {
            precondition(CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--lyricsx-phone-worker" && CommandLine.arguments[2] == "cover", "Native image connections must run in the cover worker")
        }
        self.enabled = enabled; super.init()
    }
    private var channel: IOBluetoothL2CAPChannel?
    private var deadline: Timer?
    private let serviceDiscovery = PhoneServiceDiscovery()
    private var device: IOBluetoothDevice?
    private var packets = OBEXPackets()
    private var connectionID: Data?
    private var ready = false
    private var restart: OBEXSessionRestart?
    private var handle: String?
    private var queuedHandle: String?
    private var body = Data()
    private var sequence = 0
    private var buffers: [Int: (IOBluetoothL2CAPChannel, NSMutableData)] = [:]

    static func validPSM(_ value: UInt16) -> Bool { value >= 0x1001 && value & 0x0101 == 1 }

    static func psm(in records: [IOBluetoothSDPServiceRecord]) -> UInt16? {
        // A peer can publish more than one AVRCP Target record (e.g. legacy and
        // newer versions). The first matching UUID need not advertise Cover Art.
        for record in records where record.matchesUUID16(0x110c) {
            if let psm = psm(in: record) { return psm }
        }
        return nil
    }
    static func discoverPSM(_ device: IOBluetoothDevice) -> UInt16? {
        let records = device.services as? [IOBluetoothSDPServiceRecord] ?? []
        PhoneDiagnostics.write("SDP target records=" + String(records.filter { $0.matchesUUID16(0x110c) }.count))
        return psm(in: records)
    }

    static func psm(in record: IOBluetoothSDPServiceRecord) -> UInt16? {
        PhoneDiagnostics.write("cover SDP features=" + String(record.getAttributeDataElement(0x0311)?.getNumberValue()?.uint16Value ?? 0)
            + " protocols=" + String(describing: record.getAttributeDataElement(0x000d)?.getArrayValue()))
        guard let features = record.getAttributeDataElement(0x0311)?.getNumberValue(), features.uint16Value & 0x100 != 0,
              let lists = record.getAttributeDataElement(0x000d)?.getArrayValue() as? [IOBluetoothSDPDataElement] else { return nil }
        for list in lists {
            guard let protocols = list.getArrayValue() as? [IOBluetoothSDPDataElement] else { continue }
            var psm: UInt16?
            var obex = false
            for element in protocols {
                guard let descriptor = element.getArrayValue() as? [IOBluetoothSDPDataElement], let first = descriptor.first?.getUUIDValue() else { continue }
                if first.isEqual(to: IOBluetoothSDPUUID(uuid16: 0x0100)), descriptor.count >= 2 { psm = descriptor[1].getNumberValue()?.uint16Value }
                if first.isEqual(to: IOBluetoothSDPUUID(uuid16: 0x0008)) { obex = true }
            }
            if obex, let value = psm, validPSM(value) { return value }
        }
        return nil
    }

    func connect(address: String) { connect(address: address, psm: nil) }
    func connect(address: String, psm: UInt16?) {
        PhoneDiagnostics.write("cover start endpoint=" + String(psm ?? 0))
        resetChannel()
        // A failed optional image channel must not cause a reconnect/attempt loop.
        guard enabled, !attemptedAddresses.contains(address) else { onState?(.unavailable); return }
        guard let device = IOBluetoothDevice(addressString: address), device.isPaired() else { PhoneDiagnostics.write("cover paired device unavailable"); onState?(.unavailable); return }
        attemptedAddresses.insert(address)
        onState?(.connecting)
        self.device = device
        // IPC/cache endpoints are hints only. Query the phone over SDP instead
        // of treating getLastServicesUpdate() as proof of a completed query.
        serviceDiscovery.start(device: device) { [weak self] targets in
            guard let self = self, self.device === device else { return }
            guard let targets = targets else {
                PhoneDiagnostics.write("wire SDP failed or timed out"); self.disconnect(); return
            }
            for target in targets {
                PhoneDiagnostics.write("wire SDP target version=" + String(target.version ?? 0)
                    + " features=" + String(target.features ?? 0) + " coverPSM=" + String(target.coverPSM ?? 0))
            }
            guard let endpoint = targets.compactMap({ $0.coverPSM }).first else {
                PhoneDiagnostics.write("wire SDP has no cover endpoint"); self.disconnect(); return
            }
            self.openImageChannel(device, psm: endpoint)
        }
    }
    private func openImageChannel(_ device: IOBluetoothDevice, record: IOBluetoothSDPServiceRecord) {
        guard let psm = Self.psm(in: record) else { PhoneDiagnostics.write("cover SDP has no image endpoint"); disconnect(); return }
        openImageChannel(device, psm: psm)
    }
    private func openImageChannel(_ device: IOBluetoothDevice, psm: UInt16) {
        PhoneDiagnostics.write("cover PSM found: " + String(psm))
        armDeadline()
        let result = device.openL2CAPChannelAsync(&channel, withPSM: psm, withConfiguration: [kIOBluetoothL2CAPChannelMaxAllowedIncomingMTU: 4096, kIOBluetoothL2CAPChannelDesiredOutgoingMTU: 4096], delegate: self)
        PhoneDiagnostics.write("cover L2CAP request returned: " + String(result))
        if result != kIOReturnSuccess { disconnect() }
    }
    func disconnect() { resetChannel(); onState?(.unavailable) }
    private func resetChannel() {
        serviceDiscovery.cancel(); device = nil
        deadline?.invalidate(); deadline = nil
        let previous = channel; channel = nil
        ready = false; connectionID = nil; handle = nil; queuedHandle = nil
        restart = nil
        packets = OBEXPackets(); body.removeAll()
        _ = previous?.close()
    }
    func fetch(handle: String) {
        guard ready, handle.utf8.count == 7, handle.utf8.allSatisfy({ (48...57).contains($0) }) else { return }
        guard self.handle == nil else { queuedHandle = handle; return }
        self.handle = handle; body.removeAll()
        onState?(.loading)
        var headers = idHeader()
        headers.append(OBEXPackets.header(0x42, Data("x-bt/img-thm\0".utf8)))
        headers.append(OBEXPackets.header(0x30, Data((handle + "\0").utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 255)] })))
        armDeadline()
        send(OBEXPackets.packet(0x83, headers))
    }
    func restartSession() {
        // An initial CONNECT has no retained image handles yet. Its onReady
        // already demands fresh metadata, so leave that bounded attempt intact.
        guard ready, restart == nil else { return }
        let transition = OBEXSessionRestart(imageInFlight: handle != nil)
        let action = transition.initialAction
        restart = transition; ready = false; queuedHandle = nil; body.removeAll()
        onState?(.connecting); armDeadline()
        if action == .disconnect { send(OBEXPackets.packet(0x81, idHeader())) }
    }
    private func idHeader() -> Data { connectionID.map { Data([0xcb]) + $0 } ?? Data() }
    private func armDeadline() {
        deadline?.invalidate()
        let timer = Timer(timeInterval: 8, repeats: false) { [weak self] _ in self?.disconnect() }
        deadline = timer; RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }
    func l2capChannelOpenComplete(_ channel: IOBluetoothL2CAPChannel!, status error: IOReturn) {
        PhoneDiagnostics.write("cover open callback: " + String(error) + " matched=" + String(channel === self.channel))
        guard channel === self.channel else { return }
        PhoneDiagnostics.write("cover channel open: " + String(error))
        guard error == kIOReturnSuccess else { disconnect(); return }
        sendConnect()
    }
    private func sendConnect() {
        // OBEX 1.5, maximum incoming packet 4096, AVRCP Cover Art Target UUID.
        let uuid = Data([0x71,0x63,0xdd,0x54,0x4a,0x7e,0x11,0xe2,0xb4,0x7c,0,0x50,0xc2,0x49,0,0x48])
        send(OBEXPackets.packet(0x80, Data([0x15,0,0x10,0]) + OBEXPackets.header(0x46, uuid)))
    }
    func l2capChannelData(_ channel: IOBluetoothL2CAPChannel!, data pointer: UnsafeMutableRawPointer!, length: Int) {
        guard channel === self.channel, let pointer = pointer, length > 0, length <= 65536 else { return }
        guard let responses = packets.receive(Data(bytes: pointer, count: length)) else { disconnect(); return }
        for packet in responses {
            PhoneDiagnostics.write("OBEX reply: " + String(format: "%02x", packet.first ?? 0))
            if var transition = restart {
                if transition.phase == .connecting {
                    restart = nil // normal CONNECT parsing below validates headers
                } else {
                    guard OBEXPackets.headers(packet, offset: 3) != nil else { disconnect(); return }
                    let action = transition.receive(packet.first ?? 0)
                    restart = transition; armDeadline()
                    switch action {
                    case .abort: send(OBEXPackets.packet(0xff, idHeader()))
                    case .disconnect: send(OBEXPackets.packet(0x81, idHeader()))
                    case .connect:
                        connectionID = nil; handle = nil; body.removeAll()
                        sendConnect()
                    case .fail: disconnect(); return
                    case .wait, .complete: break
                    }
                    continue
                }
            }
            guard packet.first == 0xa0 || (ready && packet.first == 0x90),
                  let headers = OBEXPackets.headers(packet, offset: ready ? 3 : 7) else { disconnect(); return }
            if !ready {
                guard packet.count >= 7 else { disconnect(); return }
                connectionID = headers[0xcb]?.first
                guard connectionID.map({ $0.count == 4 }) ?? true else { disconnect(); return }
                ready = true; deadline?.invalidate(); deadline = nil
                onState?(.ready)
                onReady?()
                continue
            }
            guard let handle = handle else { disconnect(); return }
            for bytes in (headers[0x48] ?? []) + (headers[0x49] ?? []) { body.append(bytes) }
            guard body.count <= 2 * 1024 * 1024 else { disconnect(); return }
            if packet.first == 0x90 {
                armDeadline(); send(OBEXPackets.packet(0x83, idHeader()))
            } else {
                deadline?.invalidate(); deadline = nil
                let result = body; body.removeAll(); self.handle = nil
                onImage?(handle, result)
                if let queued = queuedHandle { queuedHandle = nil; fetch(handle: queued) }
            }
        }
    }
    func l2capChannelClosed(_ channel: IOBluetoothL2CAPChannel!) {
        buffers = buffers.filter { $0.value.0 !== channel }
        _ = channel.setDelegate(nil)
        if channel === self.channel { disconnect() }
    }
    private func send(_ data: Data) {
        guard let channel = channel, data.count <= Int(channel.outgoingMTU), buffers.count < 8 else { disconnect(); return }
        sequence += 1
        let token = sequence, buffer = NSMutableData(data: data)
        buffers[token] = (channel, buffer)
        let status = channel.writeAsync(buffer.mutableBytes, length: UInt16(buffer.length), refcon: UnsafeMutableRawPointer(bitPattern: token))
        if status != kIOReturnSuccess { buffers[token] = nil; disconnect() }
    }
    func l2capChannelWriteComplete(_ channel: IOBluetoothL2CAPChannel!, refcon: UnsafeMutableRawPointer!, status error: IOReturn) {
        buffers[Int(bitPattern: refcon)] = nil
        if channel === self.channel, error != kIOReturnSuccess { disconnect() }
    }
}

/// UID invalidation ends the old OBEX namespace before requesting new handles.
/// An outstanding GET must finish its response before ABORT/DISCONNECT is sent.
struct OBEXSessionRestart {
    enum Phase { case waitingForImage, aborting, disconnecting, connecting, complete }
    enum Action { case wait, abort, disconnect, connect, complete, fail }
    private(set) var phase: Phase
    init(imageInFlight: Bool) { phase = imageInFlight ? .waitingForImage : .disconnecting }
    var initialAction: Action { phase == .waitingForImage ? .wait : .disconnect }
    mutating func receive(_ code: UInt8) -> Action {
        switch phase {
        case .waitingForImage:
            if code == 0x90 { phase = .aborting; return .abort }
            if code == 0xa0 { phase = .disconnecting; return .disconnect }
        case .aborting:
            if code == 0xa0 { phase = .disconnecting; return .disconnect }
        case .disconnecting:
            if code == 0xa0 { phase = .connecting; return .connect }
        case .connecting:
            if code == 0xa0 { phase = .complete; return .complete }
        case .complete: break
        }
        return .fail
    }
}

/// OBEX is length-delimited, independent of L2CAP callback boundaries.
struct OBEXPackets {
    private var buffer = Data()
    mutating func receive(_ data: Data) -> [Data]? {
        buffer.append(data)
        guard buffer.count <= 131072 else { buffer.removeAll(); return nil }
        var packets: [Data] = []
        while buffer.count >= 3 {
            let bytes = [UInt8](buffer.prefix(3))
            let length = Int(bytes[1]) << 8 | Int(bytes[2])
            guard length >= 3, length <= 4096 else { buffer.removeAll(); return nil }
            guard buffer.count >= length else { break }
            packets.append(Data(buffer.prefix(length))); buffer.removeFirst(length)
        }
        return packets
    }
    static func packet(_ code: UInt8, _ payload: Data) -> Data {
        let length = payload.count + 3
        return Data([code, UInt8(length >> 8), UInt8(length & 255)]) + payload
    }
    static func header(_ id: UInt8, _ payload: Data) -> Data { packet(id, payload) }
    static func headers(_ packet: Data, offset: Int) -> [UInt8: [Data]]? {
        let bytes = [UInt8](packet)
        guard offset <= bytes.count else { return nil }
        var result: [UInt8: [Data]] = [:], cursor = offset
        while cursor < bytes.count {
            let id = bytes[cursor], kind = id >> 6
            let length: Int, start: Int
            if kind < 2 {
                guard cursor + 3 <= bytes.count else { return nil }
                length = Int(bytes[cursor + 1]) << 8 | Int(bytes[cursor + 2]); start = cursor + 3
                guard length >= 3 else { return nil }
            } else { length = kind == 2 ? 2 : 5; start = cursor + 1 }
            guard cursor + length <= bytes.count else { return nil }
            result[id, default: []].append(Data(bytes[start..<cursor + length])); cursor += length
        }
        return result
    }
}
