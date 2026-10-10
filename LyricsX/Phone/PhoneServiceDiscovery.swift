import Foundation
import IOBluetooth

/// Bounded SDP ServiceSearchAttribute exchange. Native service timestamps are
/// not freshness evidence: macOS 27's getter returns the current date.
struct PhoneSDPExchange {
    private(set) var transaction: UInt16 = 0
    private var attributes = Data()
    private var tokens = Set<Data>()
    private var pages = 0
    mutating func request(continuation: Data = Data()) -> Data? {
        guard continuation.count <= 16, pages < 64,
              continuation.isEmpty || tokens.insert(continuation).inserted else { return nil }
        pages += 1; transaction &+= 1
        let params = Data([0x35,3,0x19,0x11,0x0c,0xff,0xff,0x35,5,0x0a,0,0,0xff,0xff,UInt8(continuation.count)]) + continuation
        return Data([6,UInt8(transaction >> 8),UInt8(transaction & 255),0,UInt8(params.count)]) + params
    }
    enum Response { case more(Data), complete(Data) }
    mutating func receive(_ packet: Data) -> Response? {
        let b = [UInt8](packet)
        guard b.count >= 8, b[0] == 7,
              UInt16(b[1]) << 8 | UInt16(b[2]) == transaction,
              Int(b[3]) << 8 | Int(b[4]) == b.count - 5 else { return nil }
        let count = Int(b[5]) << 8 | Int(b[6])
        guard count > 0, b.count > 7 + count, attributes.count + count <= 65536 else { return nil }
        let remaining = Int(b[7 + count])
        guard remaining <= 16, b.count == 8 + count + remaining else { return nil }
        attributes.append(contentsOf: b[7..<7 + count])
        return remaining == 0 ? .complete(attributes) : .more(Data(b.suffix(remaining)))
    }
}

struct PhoneSDPTarget {
    let version: UInt16?
    let features: UInt16?
    let coverPSM: UInt16?

    // Decode independently of IOBluetooth's service cache, including fragmented
    // attribute lists, 16/32/128-bit UUIDs and bounded nested data elements.
    private struct Element {
        let type: UInt8
        let bytes: [UInt8]
        let children: [Element]
        var number: UInt16? {
            guard type == 1, bytes.count == 2 else { return nil }
            return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        }
        func uuid(_ value: UInt16) -> Bool {
            guard type == 3 else { return false }
            let short = [UInt8(value >> 8), UInt8(value & 255)]
            return bytes == short || bytes == [0,0] + short || bytes == [0,0] + short + [0,0,0x10,0,0x80,0,0,0x80,0x5f,0x9b,0x34,0xfb]
        }
    }
    static func parse(_ data: Data) -> [PhoneSDPTarget]? {
        let bytes = [UInt8](data)
        var offset = 0, nodes = 0
        func read(_ limit: Int, _ depth: Int) -> Element? {
            guard offset < limit, depth <= 12, nodes < 4096 else { return nil }
            nodes += 1
            let descriptor = bytes[offset]; offset += 1
            let type = descriptor >> 3, size = descriptor & 7
            var length: Int
            if type == 0 { guard size == 0 else { return nil }; length = 0 }
            else if size < 5 { length = 1 << Int(size) }
            else {
                let width = 1 << Int(size - 5)
                guard offset + width <= limit else { return nil }
                length = 0
                for _ in 0..<width { length = length << 8 | Int(bytes[offset]); offset += 1 }
            }
            guard length <= limit - offset else { return nil }
            let end = offset + length
            var children = [Element]()
            if type == 6 || type == 7 {
                guard size >= 5 else { return nil }
                while offset < end { guard let child = read(end, depth + 1) else { return nil }; children.append(child) }
                return Element(type: type, bytes: [], children: children)
            }
            let payload = Array(bytes[offset..<end]); offset = end
            return Element(type: type, bytes: payload, children: [])
        }
        guard bytes.count <= 65536, let root = read(bytes.count, 0), offset == bytes.count, root.type == 6 else { return nil }
        var targets = [PhoneSDPTarget]()
        for record in root.children {
            guard record.type == 6, record.children.count % 2 == 0 else { return nil }
            var fields = [UInt16: Element]()
            for i in stride(from: 0, to: record.children.count, by: 2) {
                guard let key = record.children[i].number, fields[key] == nil else { return nil }
                fields[key] = record.children[i+1]
            }
            guard fields[1]?.type == 6, fields[1]?.children.contains(where: { $0.uuid(0x110c) }) == true else { continue }
            let version = fields[9]?.children.first(where: { $0.type == 6 && $0.children.first?.uuid(0x110e) == true })?.children.dropFirst().first?.number
            let features = fields[0x311]?.number
            var coverPSM: UInt16?
            if (features ?? 0) & 0x100 != 0, fields[0x0d]?.type == 6 {
                for list in fields[0x0d]!.children where list.type == 6 {
                    let psm = list.children.first(where: { $0.type == 6 && $0.children.first?.uuid(0x100) == true })?.children.dropFirst().first?.number
                    let obex = list.children.contains(where: { $0.type == 6 && $0.children.first?.uuid(8) == true })
                    if obex, let psm = psm, psm >= 0x1001, psm & 0x0101 == 1 { coverPSM = psm; break }
                }
            }
            targets.append(PhoneSDPTarget(version: version, features: features, coverPSM: coverPSM))
        }
        return targets
    }
}

/// Owns only its SDP channel; all callers are bounded Bluetooth workers.
final class PhoneServiceDiscovery: NSObject, IOBluetoothL2CAPChannelDelegate {
    private var device: IOBluetoothDevice?
    private var channel: IOBluetoothL2CAPChannel?
    private var timeout: Timer?
    private var exchange = PhoneSDPExchange()
    private var writes = [Int: NSMutableData]()
    private var sequence = 0
    private var completion: (([PhoneSDPTarget]?) -> Void)?

    func start(device: IOBluetoothDevice, completion: @escaping ([PhoneSDPTarget]?) -> Void) {
        precondition(CommandLine.arguments.contains("--lyricsx-phone-worker"), "SDP must run in an isolated worker")
        self.device = device; self.completion = completion
        LXPrepareBluetoothCallbacks(device)
        let timer = Timer(timeInterval: 4, repeats: false) { [weak self] _ in self?.finish(nil) }
        timeout = timer; RunLoop.main.add(timer, forMode: .common)
        let status = device.openL2CAPChannelAsync(&channel, withPSM: 1, delegate: self)
        if status != kIOReturnSuccess { finish(nil) }
    }
    func cancel() {
        completion = nil; timeout?.invalidate(); timeout = nil
        let previous = channel; channel = nil
        _ = previous?.close()
        device = nil
    }
    private func finish(_ result: [PhoneSDPTarget]?) {
        let callback = completion
        cancel(); callback?(result)
    }
    private func send(_ continuation: Data = Data()) {
        guard let channel = channel, let packet = exchange.request(continuation: continuation), packet.count <= Int(channel.outgoingMTU) else { finish(nil); return }
        sequence += 1
        let token = sequence, buffer = NSMutableData(data: packet)
        writes[token] = buffer
        let status = channel.writeAsync(buffer.mutableBytes, length: UInt16(buffer.length), refcon: UnsafeMutableRawPointer(bitPattern: token))
        if status != kIOReturnSuccess { writes[token] = nil; finish(nil) }
    }
    func l2capChannelOpenComplete(_ channel: IOBluetoothL2CAPChannel!, status: IOReturn) {
        guard channel === self.channel else { return }
        guard status == kIOReturnSuccess else { finish(nil); return }
        send()
    }
    func l2capChannelData(_ channel: IOBluetoothL2CAPChannel!, data: UnsafeMutableRawPointer!, length: Int) {
        guard channel === self.channel, completion != nil else { return }
        guard let data = data, length > 0, length <= 65536,
              let response = exchange.receive(Data(bytes: data, count: length)) else { finish(nil); return }
        switch response {
        case .more(let token): send(token)
        case .complete(let attributes): finish(PhoneSDPTarget.parse(attributes))
        }
    }
    func l2capChannelWriteComplete(_ channel: IOBluetoothL2CAPChannel!, refcon: UnsafeMutableRawPointer!, status: IOReturn) {
        writes[Int(bitPattern: refcon)] = nil
        if channel === self.channel, status != kIOReturnSuccess { finish(nil) }
    }
    func l2capChannelClosed(_ channel: IOBluetoothL2CAPChannel!) {
        _ = channel.setDelegate(nil)
        if channel === self.channel { finish(nil) }
    }
}
