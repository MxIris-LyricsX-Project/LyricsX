import Foundation
import Testing
@testable import LyricsXFoundation

struct NetEasePlaybackStateTests {
    static let value = Data([1]) + Data("rbDKWGeW7eNGtaFADOEh1cOameCaAHWRhNNjtVfl+7m0BM87IlHONqICbHFRIiwF7EHiyaNBPQ0FnEsqMPVmBQ==".utf8)
    static func number(_ value: UInt64, count: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
    static func string(_ data: Data) -> [UInt8] {
        var length = data.count, prefix: [UInt8] = []
        repeat { prefix.append(UInt8(length & 127) | (length > 127 ? 128 : 0)); length >>= 7 } while length > 0
        return prefix + data
    }
    static func batch(sequence: UInt64 = 1, deleted: Bool = false) -> [UInt8] {
        number(sequence, count: 8) + number(1, count: 4) + [deleted ? 0 : 1] + string(NetEasePlaybackState.key) + (deleted ? [] : string(value))
    }
    static func record(_ bytes: [UInt8], type: UInt8 = 1) -> Data {
        Data(number(UInt64(NetEasePlaybackState.maskedCRC([type] + bytes)), count: 4) + number(UInt64(bytes.count), count: 2) + [type] + bytes)
    }
    static func logFixture() -> Data { record(batch()) }

    @Test func decryptsClientPlaybackID() {
        #expect(NetEasePlaybackState.songID(from: Self.value) == 123)
        #expect(NetEasePlaybackState.songID(from: Data([1]) + Data("broken".utf8)) == nil)
        #expect(NetEasePlaybackState.songID(from: Data([0]) + Self.value.dropFirst()) == nil)
    }
    @Test func readsLatestCompleteWriteBatchAndDeletion() throws {
        let log = Self.logFixture() + Self.record(Self.batch(sequence: 9, deleted: true))
        let entry = try #require(NetEasePlaybackState.latestEntry(in: log))
        #expect(entry.sequence == 9)
        #expect(entry.value == nil)
    }
    @Test func ignoresPartialAndCorruptWrites() {
        let log = Self.logFixture()
        #expect(NetEasePlaybackState.latestEntry(in: log.dropLast()) == nil)
        var corrupt = Self.record(Self.batch(sequence: 9))
        corrupt[0] ^= 1
        #expect(NetEasePlaybackState.latestEntry(in: log + corrupt)?.sequence == 1)
        #expect(NetEasePlaybackState.latestEntry(in: log + Self.record(Self.batch(sequence: 9)).dropLast())?.sequence == 1)
    }
    @Test func reassemblesFragmentsAtBlockBoundary() {
        let batch = Self.batch()
        var log = Self.record(Array(batch.prefix(20)), type: 2)
        log += Data(repeating: 0, count: 32768 - log.count)
        log += Self.record(Array(batch.dropFirst(20)), type: 4)
        // A zero padding header terminates fragments; valid fragmented records
        // fill a block instead, so construct a large harmless key/value first.
        var large = Self.number(1, count: 8) + Self.number(2, count: 4) + [1] + Self.string(Data("other".utf8))
        large += Self.string(Data(repeating: 65, count: 32750))
        large += [1] + Self.string(NetEasePlaybackState.key) + Self.string(Self.value)
        let first = Self.record(Array(large.prefix(32761)), type: 2)
        let last = Self.record(Array(large.dropFirst(32761)), type: 4)
        #expect(NetEasePlaybackState.latestEntry(in: first + last)?.value == Self.value)
        #expect(NetEasePlaybackState.latestEntry(in: log) == nil)
    }
    @Test func crcMatchesLevelDBGoldenValue() {
        // CRC32C("123456789") = e3069283 before LevelDB masking.
        #expect(NetEasePlaybackState.maskedCRC(Array("123456789".utf8)) == 0xc78ab0e5)
    }
    static func tableFixture(sequence: UInt64 = 10, deleted: Bool = false) -> Data {
        func block(_ key: Data, _ value: Data) -> Data {
            Data([0] + Self.string(key).dropLast(key.count) + Self.string(value).dropLast(value.count) + key + value + Self.number(0, count: 4) + Self.number(1, count: 4))
        }
        func trailer(_ block: Data) -> Data {
            block + Data([0]) + Data(Self.number(UInt64(NetEasePlaybackState.maskedCRC(Array(block) + [0])), count: 4))
        }
        let key = NetEasePlaybackState.key + Data(Self.number(sequence << 8 | (deleted ? 0 : 1), count: 8))
        let payload = block(key, deleted ? Data() : Self.value)
        var table = trailer(payload)
        func varint(_ value: Int) -> [UInt8] {
            var value = value, bytes: [UInt8] = []
            repeat { bytes.append(UInt8(value & 127) | (value > 127 ? 128 : 0)); value >>= 7 } while value > 0
            return bytes
        }
        let index = block(key, Data([0] + varint(payload.count)))
        let indexOffset = table.count
        table += trailer(index)
        var footer = Data([0, 0] + varint(indexOffset) + varint(index.count))
        footer += Data(repeating: 0, count: 40 - footer.count)
        footer += Data(Self.number(0xdb4775248b80fb57, count: 8))
        return table + footer
    }
    @Test func readsCompactedPlaybackAndRejectsCorruptTables() {
        let table = Self.tableFixture()
        #expect(NetEasePlaybackState.latestTableEntry(in: table)?.sequence == 10)
        #expect(NetEasePlaybackState.latestTableEntry(in: table)?.value == Self.value)
        #expect(NetEasePlaybackState.latestTableEntry(in: Self.tableFixture(deleted: true))?.value == nil)
        var corrupt = table; corrupt[5] ^= 1
        #expect(NetEasePlaybackState.latestTableEntry(in: corrupt) == nil)
        #expect(NetEasePlaybackState.latestTableEntry(in: table.dropLast()) == nil)
    }
    @Test func decodesSnappyLiteralAndOverlappingCopies() {
        #expect(NetEasePlaybackState.snappy([5, 16, 104, 101, 108, 108, 111]) == Array("hello".utf8))
        #expect(NetEasePlaybackState.snappy([8, 4, 97, 98, 22, 2, 0]) == Array("abababab".utf8))
        #expect(NetEasePlaybackState.snappy([8, 4, 97, 98, 22, 0, 0]) == nil)
        #expect(NetEasePlaybackState.snappy([5, 16, 104]) == nil)
    }
    @Test func choosesNewestStateAcrossWALAndCompaction() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.logFixture().write(to: directory.appendingPathComponent("000001.log"))
        try Self.tableFixture(sequence: 10, deleted: true).write(to: directory.appendingPathComponent("000002.ldb"))
        #expect(NetEasePlaybackState.currentSongID(directory: directory) == nil)
        try Self.tableFixture(sequence: 11).write(to: directory.appendingPathComponent("000002.ldb"))
        #expect(NetEasePlaybackState.currentSongID(directory: directory) == 123)
    }

}
