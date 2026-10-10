import Foundation

/// AVRCP 1.3 metadata/control over the AVCTP control channel (PSM 0x17).
enum AVRCPCodec {
    struct Response {
        let label: UInt8
        let code: UInt8
        let pdu: UInt8
        let fragment: UInt8
        let parameters: Data
        var successful: Bool { [0x09, 0x0c, 0x0d, 0x0f].contains(code) }
    }
    struct Status {
        let duration: TimeInterval?
        let position: TimeInterval?
        let state: UInt8
    }
    static func vendor(label: UInt8, pdu: UInt8, parameters: [UInt8] = [], command: UInt8 = 1) -> Data {
        Data([(label & 15) << 4, 0x11, 0x0e, command, 0x48, 0, 0, 0x19, 0x58, pdu, 0,
              UInt8(parameters.count >> 8), UInt8(parameters.count & 255)] + parameters)
    }
    static func passThrough(label: UInt8, operation: UInt8, released: Bool) -> Data {
        Data([(label & 15) << 4, 0x11, 0x0e, 0, 0x48, 0x7c, operation | (released ? 0x80 : 0), 0])
    }
    /// IOBluetooth can deliver adjacent control messages in one callback.
    /// Split only complete, self-delimiting AV/C messages. AVCTP fragments and
    /// unknown opcodes remain untouched for the existing packet handler.
    static func controlPackets(_ data: Data) -> [Data] {
        let b = [UInt8](data)
        var offset = 0
        var packets: [Data] = []
        while offset < b.count {
            let available = b.count - offset
            guard available >= 6, b[offset] & 0x0c == 0,
                  b[offset + 1] == 0x11, b[offset + 2] == 0x0e else { return [data] }
            let length: Int
            switch b[offset + 5] {
            case 0 where available >= 13 && Array(b[(offset + 6)...(offset + 8)]) == [0, 0x19, 0x58]:
                length = 13 + (Int(b[offset + 11]) << 8 | Int(b[offset + 12]))
            case 0x7c where available >= 8:
                length = 8 + Int(b[offset + 7])
            case 0x30, 0x31:
                length = 11
            default: return [data]
            }
            guard length <= available else { return [data] }
            packets.append(Data(b[offset..<(offset + length)]))
            offset += length
        }
        return packets
    }
    static func controllerReply(_ data: Data) -> Data? {
        var bytes = [UInt8](data)
        guard bytes.count >= 6, bytes[0] & 15 == 0, bytes[1...2] == [0x11, 0x0e] else { return nil }
        bytes[0] |= 2
        bytes[3] = 8 // NOT IMPLEMENTED for unsupported Target commands.
        if bytes.count == 11, bytes[5] == 0x30 {
            bytes[3] = 0x0c
            bytes.replaceSubrange(6...10, with: [7, 0x48, 0xff, 0xff, 0xff])
        } else if bytes.count == 11, bytes[5] == 0x31, bytes[6] >> 4 == 0 {
            bytes[3] = 0x0c
            bytes.replaceSubrange(7...10, with: [0x48, 0xff, 0xff, 0xff])
        }
        return Data(bytes)
    }
    static func response(_ data: Data) -> Response? {
        let bytes = [UInt8](data)
        guard bytes.count >= 13, bytes[0] & 15 == 2, bytes[1...2] == [0x11, 0x0e],
              bytes[4] == 0x48, bytes[5] == 0, Array(bytes[6...8]) == [0, 0x19, 0x58] else { return nil }
        let length = Int(bytes[11]) << 8 | Int(bytes[12])
        guard bytes.count == 13 + length, bytes[10] & 0xfc == 0 else { return nil }
        return Response(label: bytes[0] >> 4, code: bytes[3] & 15, pdu: bytes[9], fragment: bytes[10], parameters: Data(bytes.dropFirst(13)))
    }
    static func status(_ data: Data) -> Status? {
        let b = [UInt8](data)
        guard b.count == 9, [0, 1, 2, 3, 4, 255].contains(b[8]) else { return nil }
        func time(_ offset: Int) -> TimeInterval? {
            let value = b[offset..<offset+4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            return value == .max ? nil : Double(value) / 1000
        }
        return Status(duration: time(0), position: time(4), state: b[8])
    }
    static func attributes(_ data: Data) -> [UInt32: String]? {
        let b = [UInt8](data)
        guard let count = b.first else { return nil }
        var offset = 1
        var result: [UInt32: String] = [:]
        for _ in 0..<count {
            guard offset + 8 <= b.count else { return nil }
            let id = b[offset..<offset+4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let charset = UInt16(b[offset+4]) << 8 | UInt16(b[offset+5])
            let length = Int(b[offset+6]) << 8 | Int(b[offset+7])
            offset += 8
            guard offset + length <= b.count else { return nil }
            let value = Data(b[offset..<offset+length])
            let encoding: String.Encoding?
            switch charset {
            case 106: encoding = .utf8
            case 3: encoding = .ascii
            case 4: encoding = .isoLatin1
            case 1013: encoding = .utf16BigEndian
            case 1014: encoding = .utf16LittleEndian
            default: encoding = nil
            }
            if let encoding = encoding, let string = String(data: value, encoding: encoding) { result[id] = string }
            offset += length
        }
        return offset == b.count ? result : nil
    }
}

/// AVCTP fragmentation is separate from AVRCP's vendor-PDU continuation mechanism.
struct AVCTPAssembler {
    private var partial: Data?
    private var label: UInt8 = 0
    private var remaining = 0
    mutating func reset() { partial = nil; remaining = 0 }
    mutating func receive(_ data: Data) -> Data? {
        let b = [UInt8](data)
        guard let header = b.first, header & 3 == 2 else { reset(); return nil }
        let packetType = (header >> 2) & 3
        if packetType == 0 { reset(); return data }
        if packetType == 1 {
            reset()
            guard b.count >= 4, b[1] >= 2, b[2...3] == [0x11, 0x0e] else { return nil }
            label = header >> 4
            remaining = Int(b[1]) - 1
            partial = Data([(label << 4) | 2, 0x11, 0x0e] + b.dropFirst(4))
            return nil
        }
        guard partial != nil, label == header >> 4, remaining > 0,
              (packetType == 3) == (remaining == 1) else { reset(); return nil }
        partial?.append(contentsOf: b.dropFirst())
        remaining -= 1
        guard (partial?.count ?? 0) <= 65536 else { reset(); return nil }
        if remaining == 0 { let result = partial; reset(); return result }
        return nil
    }
}
