import Foundation
import IOBluetooth

@main enum PhoneServiceDiscoveryProbe {
    static func main() {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { print("FAIL " + name); exit(1) }
            count += 1; print("PASS " + name)
        }
        func hex(_ s: String) -> Data { let c = Array(s); return Data(stride(from: 0, to: c.count, by: 2).map { UInt8(String(c[$0..<$0+2]),radix:16)! }) }
        // Real on-wire Target response, stripped of device address/identity.
        let actual = hex("35ba35b80900000a4f49110c090001350319110c0900020a000000000900043510350619010009001735061900170901040900053503191002090006352409656e09006a09010009667209006a09011009646509006a090120096a6109006a09013009000808ff0900093508350619110e09010509000d35123510350619010009001b3506190017090104090100250c415652435020446576696365090101251552656d6f746520436f6e74726f6c204465766963650903110900d1")
        let parsed = PhoneSDPTarget.parse(actual)
        check(parsed?.count == 1 && parsed?.first?.version == 0x105, "real wire response identifies AVRCP 1.5 Target")
        check(parsed?.first?.features == 0xd1 && parsed?.first?.coverPSM == nil, "browsing endpoint is never mistaken for BIP")
        func seq(_ bytes: Data) -> Data { Data([0x35,UInt8(bytes.count)]) + bytes }
        func u16(_ n: UInt16) -> Data { Data([9,UInt8(n >> 8),UInt8(n & 255)]) }
        func target(_ features: UInt16, _ port: UInt16, _ obex: Bool, _ uuid: Data = Data([0x19,0x11,0x0c])) -> Data {
            let service = u16(1) + seq(uuid)
            let profile = u16(9) + seq(seq(hex("19110e") + u16(0x106)))
            let protocols = u16(0x0d) + seq(seq(seq(hex("190100") + u16(port)) + seq(hex(obex ? "190008" : "190017"))))
            return seq(service + profile + protocols + u16(0x311) + u16(features))
        }
        let cover = target(0x1d1,0x1009,true)
        check(PhoneSDPTarget.parse(seq(cover))?.first?.coverPSM == 0x1009, "cover bit and OBEX dynamic endpoint accepted")
        check(PhoneSDPTarget.parse(seq(target(0xd1,0x1009,true)))?.first?.coverPSM == nil, "missing cover feature rejected")
        check(PhoneSDPTarget.parse(seq(target(0x1d1,0x1009,false)))?.first?.coverPSM == nil, "missing OBEX descriptor rejected")
        check(PhoneSDPTarget.parse(seq(target(0x1d1,0x1010,true)))?.first?.coverPSM == nil, "invalid PSM rejected")
        check(PhoneSDPTarget.parse(seq(target(0x1d1,0x1009,true,hex("1c0000110c00001000800000805f9b34fb"))))?.first?.coverPSM == 0x1009, "Bluetooth base UUID accepted")
        check(PhoneSDPTarget.parse(seq(target(0xd1,0x1b,false) + cover))?.compactMap({ $0.coverPSM }) == [0x1009], "multiple Target records searched")
        check(PhoneSDPTarget.parse(actual.dropLast()) == nil, "truncated data element rejected")
        check(PhoneSDPTarget.parse(actual + Data([0])) == nil, "trailing data rejected")
        var nested = Data([0]); for _ in 0..<15 { nested = seq(nested) }
        check(PhoneSDPTarget.parse(nested) == nil, "nesting bounded")
        var exchange = PhoneSDPExchange()
        let request = exchange.request()!
        check(request == hex("060001000f350319110cffff35050a0000ffff00"), "standard all-attributes Target query encoded")
        func reply(_ txn: UInt16, _ payload: Data, _ token: Data = Data()) -> Data {
            let p = Data([UInt8(payload.count >> 8),UInt8(payload.count & 255)]) + payload + Data([UInt8(token.count)]) + token
            return Data([7,UInt8(txn >> 8),UInt8(txn & 255),UInt8(p.count >> 8),UInt8(p.count & 255)]) + p
        }
        let token = Data([1,2,3])
        if case .more(let received)? = exchange.receive(reply(1,actual.prefix(30),token)) { check(received == token,"continuation preserved") } else { check(false,"continuation response") }
        check(exchange.request(continuation:token) != nil, "continued request advances transaction")
        if case .complete(let result)? = exchange.receive(reply(2,actual.dropFirst(30))) { check(result == actual,"fragmented attribute list reassembled") } else { check(false,"final response") }
        check(exchange.request(continuation:token) == nil, "repeated continuation token rejected")
        check(exchange.receive(reply(1,actual)) == nil, "stale transaction rejected")
        check(exchange.receive(reply(2,actual).dropLast()) == nil, "inconsistent PDU length rejected")
        check(exchange.request(continuation:Data(repeating:1,count:17)) == nil, "oversize continuation rejected")
        print("\(count) SDP checks passed")
    }
}
