import Foundation
import CommonCrypto

/// Reads only NetEase 3.1.13's lastPlaying key, without opening or locking
/// the client's LevelDB. Incomplete writes and invalid checksums are ignored.
enum NetEasePlaybackState {
    static let key = Data("_orpheus://orpheus\0\u{1}lastPlaying".utf8)
    static let directoryURL = NetEaseClientTrackResolver.databaseURL.deletingLastPathComponent()
        .appendingPathComponent("CEFCache/Local Storage/leveldb")
    struct Entry { let sequence: UInt64; let value: Data? }

    static func currentSongID(directory: URL = directoryURL) -> Int64? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
        var newest: Entry?
        var budget = 32 * 1024 * 1024
        for file in files.filter({ ["log", "ldb"].contains($0.pathExtension) }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= budget, size <= 16 * 1024 * 1024,
                  let data = try? Data(contentsOf: file) else { return nil }
            budget -= size
            if let entry = file.pathExtension == "log" ? latestEntry(in: data) : latestTableEntry(in: data), newest == nil || entry.sequence > newest!.sequence { newest = entry }
        }
        guard let value = newest?.value else { return nil }
        return songID(from: value)
    }

    static func songID(from value: Data) -> Int64? {
        // Chromium localStorage values use a one-byte Latin-1 marker.
        guard value.first == 1, let text = String(data: value.dropFirst(), encoding: .utf8),
              let encrypted = Data(base64Encoded: text), !encrypted.isEmpty, encrypted.count <= 4096 else { return nil }
        // Matches the installed client's enData/deData AES-128 ECB routine.
        // This is a fixed local-format key, unrelated to account credentials.
        let aesKey = Array(")(13daqP@ssw0rd~~I".utf8.prefix(kCCKeySizeAES128))
        var plaintext = [UInt8](repeating: 0, count: encrypted.count + kCCBlockSizeAES128)
        var count = 0
        let status = plaintext.withUnsafeMutableBytes { output in
            aesKey.withUnsafeBytes { key in
                encrypted.withUnsafeBytes { input in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                            key.baseAddress, kCCKeySizeAES128, nil, input.baseAddress, input.count, output.baseAddress, output.count, &count)
                }
            }
        }
        guard status == kCCSuccess,
              let state = try? JSONSerialization.jsonObject(with: Data(plaintext.prefix(count))) as? [String: Any],
              let resource = state["resourceId"] as? String, let track = state["trackId"] as? String,
              resource == track, let id = Int64(track), id > 0 else { return nil }
        return id
    }

    static func latestEntry(in data: Data) -> Entry? {
        let bytes = Array(data)
        var offset = 0, fragment: [UInt8] = [], assembling = false
        var latest: Entry?
        while offset + 7 <= bytes.count {
            let remaining = 32768 - offset % 32768
            if remaining < 7 { offset += remaining; continue }
            let length = Int(bytes[offset + 4]) | Int(bytes[offset + 5]) << 8
            let type = bytes[offset + 6]
            if length == 0 && type == 0 { offset += remaining; assembling = false; fragment = []; continue }
            guard length + 7 <= remaining, offset + 7 + length <= bytes.count else { break }
            let body = Array(bytes[(offset + 7)..<(offset + 7 + length)])
            let expected = littleEndian(bytes, at: offset, count: 4)
            offset += 7 + length
            guard UInt64(maskedCRC([type] + body)) == expected else { assembling = false; fragment = []; continue }
            var batch: [UInt8]?
            switch type {
            case 1: batch = body; assembling = false; fragment = []
            case 2: fragment = body; assembling = true
            case 3 where assembling: fragment += body
            case 4 where assembling: fragment += body; batch = fragment; fragment = []; assembling = false
            default: fragment = []; assembling = false
            }
            if fragment.count > 16 * 1024 * 1024 { return nil }
            if let batch, let entry = parseBatch(batch), latest == nil || entry.sequence > latest!.sequence { latest = entry }
        }
        return latest
    }

    private static func parseBatch(_ bytes: [UInt8]) -> Entry? {
        guard bytes.count >= 12 else { return nil }
        let sequence = littleEndian(bytes, at: 0, count: 8)
        let count = littleEndian(bytes, at: 8, count: 4)
        guard count <= 100000, sequence <= UInt64.max - count else { return nil }
        var offset = 12, entry: Entry?
        for index in 0..<count {
            guard offset < bytes.count else { return nil }
            let type = bytes[offset]; offset += 1
            guard type == 0 || type == 1, let entryKey = readString(bytes, offset: &offset) else { return nil }
            var value: Data?
            if type == 1 {
                guard let parsed = readString(bytes, offset: &offset) else { return nil }
                value = parsed
            }
            if entryKey == key { entry = Entry(sequence: sequence + index, value: value) }
        }
        return offset == bytes.count ? entry : nil
    }

    /// LevelDB moves settled keys into SSTables during compaction. Reading
    /// tables as well as the WAL keeps paused playback available after rotation.
    static func latestTableEntry(in data: Data) -> Entry? {
        let bytes = Array(data)
        guard bytes.count >= 48, littleEndian(bytes, at: bytes.count - 8, count: 8) == 0xdb4775248b80fb57 else { return nil }
        var footer = bytes.count - 48
        guard readVarint(bytes, offset: &footer) != nil, readVarint(bytes, offset: &footer) != nil,
              let indexOffset = readVarint(bytes, offset: &footer), let indexSize = readVarint(bytes, offset: &footer),
              let index = tableBlock(bytes, offset: indexOffset, size: indexSize), let handles = blockEntries(index) else { return nil }
        var latest: Entry?
        for (_, handle) in handles {
            var cursor = 0
            guard let offset = readVarint(handle, offset: &cursor), let size = readVarint(handle, offset: &cursor),
                  let block = tableBlock(bytes, offset: offset, size: size), let entries = blockEntries(block) else { return nil }
            for (internalKey, value) in entries {
                guard internalKey.count >= 8, Data(internalKey.dropLast(8)) == key else { continue }
                let tag = littleEndian(internalKey, at: internalKey.count - 8, count: 8), type = tag & 255
                guard type == 0 || type == 1 else { return nil }
                let entry = Entry(sequence: tag >> 8, value: type == 1 ? Data(value) : nil)
                if latest == nil || entry.sequence > latest!.sequence { latest = entry }
            }
        }
        return latest
    }

    private static func tableBlock(_ bytes: [UInt8], offset: Int, size: Int) -> [UInt8]? {
        guard offset >= 0, size >= 0, size <= bytes.count - 5, offset <= bytes.count - size - 5 else { return nil }
        let payload = Array(bytes[offset..<(offset + size)])
        let compression = bytes[offset + size]
        guard UInt64(maskedCRC(payload + [compression])) == littleEndian(bytes, at: offset + size + 1, count: 4) else { return nil }
        switch compression {
        case 0: return payload
        case 1: return snappy(payload)
        default: return nil
        }
    }

    private static func blockEntries(_ bytes: [UInt8]) -> [([UInt8], [UInt8])]? {
        guard bytes.count >= 4 else { return nil }
        let restartCount = littleEndian(bytes, at: bytes.count - 4, count: 4)
        guard restartCount <= UInt64((bytes.count - 4) / 4) else { return nil }
        let end = bytes.count - 4 - Int(restartCount) * 4
        var cursor = 0, previous: [UInt8] = [], entries: [([UInt8], [UInt8])] = []
        while cursor < end {
            guard let shared = readVarint(bytes, offset: &cursor), let fresh = readVarint(bytes, offset: &cursor),
                  let valueSize = readVarint(bytes, offset: &cursor), shared <= previous.count,
                  fresh <= end - cursor, valueSize <= end - cursor - fresh else { return nil }
            let key = Array(previous.prefix(shared)) + bytes[cursor..<(cursor + fresh)]; cursor += fresh
            let value = Array(bytes[cursor..<(cursor + valueSize)]); cursor += valueSize
            entries.append((key, value)); previous = key
        }
        return cursor == end ? entries : nil
    }

    static func snappy(_ bytes: [UInt8]) -> [UInt8]? {
        var cursor = 0
        guard let size = readVarint(bytes, offset: &cursor), size <= 16 * 1024 * 1024 else { return nil }
        var result: [UInt8] = []
        result.reserveCapacity(size)
        while cursor < bytes.count && result.count < size {
            let tag = bytes[cursor]; cursor += 1
            let type = tag & 3
            if type == 0 {
                var length = Int(tag >> 2) + 1
                if length > 60 {
                    let count = length - 60
                    guard count <= 4, cursor + count <= bytes.count else { return nil }
                    length = Int(littleEndian(bytes, at: cursor, count: count)) + 1; cursor += count
                }
                guard length <= bytes.count - cursor, length <= size - result.count else { return nil }
                result += bytes[cursor..<(cursor + length)]; cursor += length
            } else {
                let count = type == 1 ? 1 : type == 2 ? 2 : 4
                guard cursor + count <= bytes.count else { return nil }
                let offset = Int(littleEndian(bytes, at: cursor, count: count)) | (type == 1 ? Int(tag & 224) << 3 : 0)
                let length = type == 1 ? Int((tag >> 2) & 7) + 4 : Int(tag >> 2) + 1
                cursor += count
                guard offset > 0, offset <= result.count, length <= size - result.count else { return nil }
                for _ in 0..<length { result.append(result[result.count - offset]) }
            }
        }
        return cursor == bytes.count && result.count == size ? result : nil
    }

    private static func readVarint(_ bytes: [UInt8], offset: inout Int) -> Int? {
        var result: UInt64 = 0, shift = 0
        while offset < bytes.count && shift <= 63 {
            let byte = bytes[offset]; offset += 1
            guard shift != 63 || byte <= 1 else { return nil }
            result |= UInt64(byte & 127) << shift
            if byte < 128 { return Int(exactly: result) }
            shift += 7
        }
        return nil
    }

    private static func readString(_ bytes: [UInt8], offset: inout Int) -> Data? {
        var length = 0, shift = 0
        while offset < bytes.count && shift <= 28 {
            let byte = bytes[offset]; offset += 1
            length |= Int(byte & 127) << shift
            if byte < 128 {
                guard length <= bytes.count - offset else { return nil }
                defer { offset += length }
                return Data(bytes[offset..<(offset + length)])
            }
            shift += 7
        }
        return nil
    }

    private static func littleEndian(_ bytes: [UInt8], at offset: Int, count: Int) -> UInt64 {
        (0..<count).reduce(0) { $0 | UInt64(bytes[offset + $1]) << ($1 * 8) }
    }
    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0x82f63b78 : 0) }
        return crc
    }
    static func maskedCRC(_ bytes: [UInt8]) -> UInt32 {
        var crc = UInt32.max
        for byte in bytes { crc = crcTable[Int((crc ^ UInt32(byte)) & 255)] ^ (crc >> 8) }
        crc = ~crc
        return ((crc >> 15) | (crc << 17)) &+ 0xa282ead8
    }
}
