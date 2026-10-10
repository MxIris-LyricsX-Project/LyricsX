import AppKit
import Combine
import IOBluetooth
import MusicPlayer

private final class Wire: PhoneTransport {
    var onOpen: (() -> Void)?
    var onData: ((Data) -> Void)?
    var onClose: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    var coverPSM: UInt16? = 0x1009
    var sent: [Data] = []
    var addresses: [String] = []
    var disconnects = 0
    func connect(address: String) { addresses.append(address) }
    func disconnect() { disconnects += 1 }
    var acknowledgeCommands = true
    func send(_ data: Data) {
        sent.append(data)
        if acknowledgeCommands, data.count == 8, data[5] == 0x7c {
            var reply = data; reply[0] |= 2; reply[3] = 9
            onData?(reply)
        }
    }
    func command(_ pdu: UInt8, event: UInt8? = nil) -> Data? {
        sent.last { packet in let b = [UInt8](packet); return b.count >= 13 && b[9] == pdu && (event == nil || b[13] == event) }
    }
    func answer(_ command: Data, _ parameters: [UInt8], code: UInt8 = 0x0c, fragment: UInt8 = 0, pdu: UInt8? = nil) {
        let b = [UInt8](command)
        onData?(Data([b[0] | 2, 0x11, 0x0e, code, 0x48, 0, 0, 0x19, 0x58, pdu ?? b[9], fragment, UInt8(parameters.count >> 8), UInt8(parameters.count & 255)] + parameters))
    }
}

private final class ArtworkWire: PhoneArtworkTransport {
    var onReady: (() -> Void)?
    var onImage: ((String, Data) -> Void)?
    var onState: ((PhoneArtworkState) -> Void)?
    var endpoints: [UInt16?] = []
    var handles: [String] = []
    var sessionRestarts = 0
    func connect(address: String) {}
    func connect(address: String, psm: UInt16?) { endpoints.append(psm) }
    func fetch(handle: String) { handles.append(handle) }
    func restartSession() { sessionRestarts += 1 }
    func disconnect() {}
}

@main private enum PhonePlayerProbe {
    static func main() {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
            count += 1; print("PASS: \(message)")
        }
        // Candidate filtering is independent of AVRCP capability and device names.
        for minor: UInt32 in [0, 1, 3] {
            check(PhonePairedDevice.isMobileClass(major: 2, minor: minor), "phone class \(minor) is visible")
        }
        for minor: UInt32 in [4, 5, 7] {
            check(PhonePairedDevice.isMobileClass(major: 1, minor: minor), "handheld/tablet class \(minor) is visible")
        }
        for minor: UInt32 in [0, 1, 2, 3, 6] {
            check(!PhonePairedDevice.isMobileClass(major: 1, minor: minor), "non-mobile computer class \(minor) is hidden")
        }
        for minor: UInt32 in [2, 4, 5] {
            check(!PhonePairedDevice.isMobileClass(major: 2, minor: minor), "cordless/gateway phone class \(minor) is hidden")
        }
        for major: UInt32 in [0, 3, 4, 5, 6, 7, 8, 9, 31] {
            check(!PhonePairedDevice.isMobileClass(major: major, minor: 7), "other major class \(major) is hidden even with tablet minor")
        }
        let tablet = PhonePairedDevice(address: "fixture", name: "Tablet", isMobile: true)
        let encodedTablet = try! JSONEncoder().encode(tablet)
        check((try! JSONDecoder().decode(PhonePairedDevice.self, from: encodedTablet)).isMobile, "mobile classification survives worker IPC")
        // Literal AVRCP 1.3 wire fixtures: times are milliseconds in network order.
        let playing: [UInt8] = [0, 2, 0xbf, 0x20, 0, 0, 0x30, 0x39, 1] // 180 s, 12.345 s
        let paused: [UInt8] = [0, 2, 0xbf, 0x20, 0, 0, 0xea, 0x60, 2] // 60 s
        let unknown: [UInt8] = [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 1]
        let song: [UInt8] = [3, 0,0,0,1, 0,106, 0,4, 0x53,0x6f,0x6e,0x67,
                            0,0,0,2, 0,106, 0,6, 0x41,0x72,0x74,0x69,0x73,0x74,
                            0,0,0,3, 0,106, 0,5, 0x41,0x6c,0x62,0x75,0x6d]
        check(AVRCPCodec.vendor(label: 2, pdu: 0x30) == Data([0x20,0x11,0x0e,1,0x48,0,0,0x19,0x58,0x30,0,0,0]), "GetPlayStatus standard command frame")
        check(AVRCPCodec.passThrough(label: 3, operation: 0x44, released: true) == Data([0x30,0x11,0x0e,0,0x48,0x7c,0xc4,0]), "released play button frame")
        let status = AVRCPCodec.status(Data(playing))!
        check(status.duration == 180 && status.position == 12.345 && status.state == 1, "millisecond position and duration decoding")
        check(AVRCPCodec.status(Data(unknown))?.position == nil, "unknown-position sentinel is not a timestamp")
        check(AVRCPCodec.status(Data(playing.dropLast())) == nil, "truncated status rejected")
        check(AVRCPCodec.status(Data(playing.dropLast() + [6])) == nil, "reserved playback state rejected")
        check(AVRCPCodec.attributes(Data(song))?[2] == "Artist", "title artist album attributes")
        check(AVRCPCodec.attributes(Data(song.dropLast())) == nil, "truncated attribute value rejected")
        check(AVRCPCodec.attributes(Data(song + [0])) == nil, "trailing attribute bytes rejected")
        check(AVRCPCodec.attributes(Data([1,0,0,0,1,3,0xf5,0,2,0x4e,0x2d]))?[1] == "中", "UTF-16 big-endian metadata")
        check(AVRCPCodec.attributes(Data([1,0,0,0,1,0,4,0,1,0xe9]))?[1] == "é", "Latin-1 metadata")
        let response = Data([0x22,0x11,0x0e,0xc,0x48,0,0,0x19,0x58,0x30,0,0,9] + playing)
        check(AVRCPCodec.response(response)?.label == 2, "response matches transaction label")
        check(AVRCPCodec.response(Data(response.dropLast())) == nil, "PDU length mismatch rejected")
        var assembler = AVCTPAssembler()
        let start = Data([0x26,2,0x11,0x0e] + response.dropFirst(3).prefix(5))
        let end = Data([0x2e] + response.dropFirst(8))
        check(assembler.receive(start) == nil && assembler.receive(end) == response, "AVCTP fragments reassemble into exact response")
        _ = assembler.receive(start)
        check(assembler.receive(Data([0x3e] + response.dropFirst(8))) == nil && assembler.receive(end) == nil, "mismatched fragmented transaction discarded")
        check(AVRCPCodec.controllerReply(Data([0x10,0x11,0x0e,1,0xff,0x30,0xff,0xff,0xff,0xff,0xff])) == Data([0x12,0x11,0x0e,0x0c,0xff,0x30,7,0x48,0xff,0xff,0xff]), "UNIT INFO responds with panel subunit")
        // Parsing a local service dictionary does not publish it or access a phone.
        var attributes: [NSNumber: IOBluetoothSDPDataElement] = [:]
        for (key, value) in PhoneBluetoothTransport.controllerService {
            guard let id = UInt16(key, radix: 16) else { continue }
            attributes[NSNumber(value: id)] = IOBluetoothSDPDataElement(elementValue: (value as! NSObject))
        }
        let record = IOBluetoothSDPServiceRecord(serviceDictionary: attributes, device: nil)!
        var psm: BluetoothL2CAPPSM = 0
        check(record.getL2CAPPSM(&psm) == kIOReturnSuccess && psm == 0x17, "SDP advertises AVRCP control PSM")
        check(record.getAttributeDataElement(0x0311)?.getNumberValue()?.uint16Value == 0x0201, "controller dictionary encodes thumbnail capability in network byte order")
        check(record.matchesUUID16(0x110f) && !record.matchesUUID16(0x110b), "controller SDP contains no A2DP audio sink")
        check(NativePhoneBluetoothTransport.ownsControllerRecord(record), "only matching LyricsX controller records are owned")
        func uint16(_ value: UInt16) -> [String: Any] { ["DataElementType":1,"DataElementSize":2,"DataElementValue":NSNumber(value:value)] }
        func uuid(_ value: UInt16) -> Data { Data([UInt8(value >> 8), UInt8(value & 255)]) }
        let coverRecord = IOBluetoothSDPServiceRecord(serviceDictionary: [
            NSNumber(value:0x0001):IOBluetoothSDPDataElement(elementValue:[uuid(0x110c)] as NSArray)!,
            NSNumber(value:0x0311):IOBluetoothSDPDataElement(elementValue:uint16(0x100) as NSDictionary)!,
            NSNumber(value:0x000d):IOBluetoothSDPDataElement(elementValue:[[[uuid(0x0100),uint16(0x1b)],[uuid(0x0017),uint16(0x0104)]],[[uuid(0x0100),uint16(0x1001)],[uuid(0x0008)]]] as NSArray)!,
        ], device:nil)!
        let legacyRecord = IOBluetoothSDPServiceRecord(serviceDictionary: [
            NSNumber(value:0x0001):IOBluetoothSDPDataElement(elementValue:[uuid(0x110c)] as NSArray)!,
            NSNumber(value:0x0311):IOBluetoothSDPDataElement(elementValue:uint16(0xd1) as NSDictionary)!,
        ], device:nil)!
        check(!NativePhoneBluetoothTransport.ownsControllerRecord(legacyRecord), "system or unrelated SDP records are never removed as LyricsX records")
        check(NativePhoneCoverArt.psm(in:[legacyRecord,coverRecord]) == 0x1001, "cover discovery examines later target records after a legacy target")
        check(NativePhoneCoverArt.psm(in:[legacyRecord]) == nil, "peer with no advertised cover endpoint is not probed at a guessed port")
        check(PhoneCoverArt.psm(in:coverRecord) == 0x1001, "cover discovery selects advertised OBEX PSM instead of browsing PSM")
        check(!NativePhoneCoverArt.validPSM(0x17) && !NativePhoneCoverArt.validPSM(0x1000) && !NativePhoneCoverArt.validPSM(0x1101) && NativePhoneCoverArt.validPSM(0x1009), "cover endpoint rejects fixed, even and invalid L2CAP PSMs")
        check(PhoneCoverArt.psm(in:record) == nil, "controller service is not mistaken for cover art target")
        var defaultCoverState: PhoneArtworkState?
        let defaultCover = NativePhoneCoverArt()
        defaultCover.onState = { defaultCoverState = $0 }
        defaultCover.connect(address: "00-00-00-00-00-01")
        check(defaultCoverState == .unavailable, "default cover transport never starts the unsafe native image connection")
        var obex = OBEXPackets()
        let obexConnect = Data([0xa0,0,12,0x15,0,0x10,0,0xcb,0,0,0,1])
        check(obex.receive(Data(obexConnect.prefix(2))) == [] && obex.receive(Data(obexConnect.dropFirst(2))) == [obexConnect], "OBEX packet framing tolerates split length header")
        check(OBEXPackets.headers(obexConnect,offset:7)?[0xcb] == [Data([0,0,0,1])], "OBEX connect connection-ID header decoding")
        let firstBody = Data([0x90,0,10,0x48,0,7,1,2,3,4])
        let lastBody = Data([0xa0,0,8,0x49,0,5,5,6])
        check(obex.receive(firstBody + lastBody) == [firstBody,lastBody], "OBEX callback can contain multiple body packets")
        check(OBEXPackets.headers(lastBody,offset:3)?[0x49] == [Data([5,6])], "OBEX final body header is retained")
        check(OBEXPackets.headers(Data([0xa0,0,6,0x49,0,20]),offset:3) == nil, "OBEX truncated body header rejected")
        check(obex.receive(Data([0xa0,0,2])) == nil, "OBEX invalid packet length rejected")
        var idleRestart = OBEXSessionRestart(imageInFlight: false)
        check(idleRestart.initialAction == .disconnect && idleRestart.receive(0xa0) == .connect && idleRestart.receive(0xa0) == .complete, "idle UID invalidation disconnects OBEX before reconnecting")
        var busyRestart = OBEXSessionRestart(imageInFlight: true)
        check(busyRestart.initialAction == .wait && busyRestart.receive(0x90) == .abort, "UID invalidation waits for outstanding GET then aborts continuation")
        check(busyRestart.receive(0xa0) == .disconnect && busyRestart.receive(0xa0) == .connect, "successful ABORT precedes DISCONNECT and fresh CONNECT")
        var finalRestart = OBEXSessionRestart(imageInFlight: true)
        check(finalRestart.receive(0xa0) == .disconnect, "completed GET can disconnect without an unnecessary abort")
        var failedRestart = OBEXSessionRestart(imageInFlight: false)
        check(failedRestart.receive(0xc0) == .fail, "failed OBEX session reset cannot declare the new namespace ready")
        let suite = "LyricsX.PhoneProbe." + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        prefs.set(true, forKey: "PhoneBluetoothEnabled")
        defer { prefs.removePersistentDomain(forName: suite) }
        let wire = Wire()
        let artworkWire = ArtworkWire()
        var time = Date()
        let phone = PhonePlayer(transport: wire, coverArt: artworkWire, preferences: prefs, now: { time })
        check(phone.currentTrack == nil && phone.playbackState == .stopped, "phone source starts empty")
        phone.remember(address: "00-00-00-00-00-01", name: "Test Phone")
        phone.setActive(true)
        check(wire.addresses.count == 1 && phone.isConnecting && phone.deviceName == "Test Phone", "pinning remembered phone initiates one connection")
        wire.onOpen?()
        check(phone.isConnected && !phone.isConnecting, "channel open starts capability checks")
        check(artworkWire.endpoints.last! == 0x1009, "paired phone cover endpoint discovered by media is forwarded to image transport")
        let initialStatus = wire.command(0x30)!
        let initialMetadata = wire.command(0x20)!
        check([UInt8](initialMetadata).suffix(9).allSatisfy { $0 == 0 }, "metadata request asks for all attributes of current element")
        wire.answer(initialMetadata, song)
        wire.answer(initialStatus, playing)
        check(phone.currentTrack?.title == "Song" && phone.currentTrack?.artist == "Artist" && phone.currentTrack?.duration == 180, "phone metadata feeds MusicTrack for existing lyrics search")
        check(phone.playbackState.isPlaying && abs(phone.playbackTime - 12.345) < 0.15, "phone position drives existing lyrics clock")
        var lyricTrackEvents = 0
        let observation = phone.currentTrackWillChange.sink { _ in lyricTrackEvents += 1 }
        time = time.addingTimeInterval(1); phone.updatePlayerState()
        check(wire.command(0x20) != initialMetadata, "one-second fallback refreshes song metadata without waiting five seconds")
        let coveredSong = [UInt8(4)] + song.dropFirst() + [0,0,0,8,0,106,0,7] + Array("1000001".utf8)
        wire.answer(wire.command(0x20)!, Array(coveredSong))
        check(artworkWire.handles == ["1000001"], "cover handle is requested from separate phone image transport")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:2,pixelsHigh:2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        bitmap.setColor(NSColor(deviceRed:0,green:0,blue:1,alpha:1), atX:0, y:0)
        let imageData = bitmap.representation(using:.png,properties:[:])!
        let beforeCover = lyricTrackEvents
        artworkWire.onImage?("1000001",imageData)
        check(phone.currentTrack?.artwork != nil, "phone cover image populates native MusicTrack artwork")
        check(lyricTrackEvents == beforeCover, "artwork arrival does not cancel or restart lyric search")
        artworkWire.onImage?("1000002",imageData)
        check(phone.currentTrack?.artwork != nil, "wrong image handle cannot replace current artwork")
        observation.cancel()
        phone.playbackTime = 90
        check(abs(phone.playbackTime - 12.345) < 0.15, "unsupported absolute seek does not change clock")
        wire.answer(wire.command(0x10)!, [3,3,1,2,5])
        let trackNotification = wire.command(0x31, event: 2)!
        wire.answer(trackNotification, [2,0,0,0,0,0,0,0,1], code: 0x0f)
        for event: UInt8 in [1,5] { wire.answer(wire.command(0x31, event: event)!, event == 1 ? [1,1] : [5,0,0,0x30,0x39], code: 0x0f) }
        phone.pause()
        let controlPackets = wire.sent.filter { $0.count == 8 && $0[5] == 0x7c }
        check(controlPackets.count == 2 && controlPackets[0][6] == 0x46 && controlPackets[1][6] == 0xc6, "pause sends press and release")
        check(controlPackets[0][0] != controlPackets[1][0] && ![UInt8](trackNotification).prefix(1).contains(controlPackets[0][0]), "control transactions have distinct reserved labels")
        wire.answer(wire.command(0x30)!, paused)
        check(!phone.playbackState.isPlaying && phone.playbackTime == 60, "pause freezes lyrics at reported time")
        for packet in controlPackets { var b = [UInt8](packet); b[0] |= 2; b[3] = 9; wire.onData?(Data(b)) }
        time = time.addingTimeInterval(5)
        phone.updatePlayerState()
        let staleMetadata = wire.command(0x20)!
        let staleStatus = wire.command(0x30)!
        wire.answer(trackNotification, [2,0,0,0,0,0,0,0,2], code: 0x0d)
        check(phone.currentTrack == nil && phone.isLoadingTrack, "track-change notification clears lyrics without inventing a stopped state")
        wire.answer(staleMetadata, song)
        wire.answer(staleStatus, playing)
        check(phone.currentTrack == nil && phone.playbackTime == 0, "late previous-track packets cannot restore stale song or position")
        let nextMetadata = wire.command(0x20)!
        wire.answer(nextMetadata, Array(song.prefix(12)), fragment: 1)
        check(phone.currentTrack == nil && wire.command(0x40) != nil, "long metadata requests vendor continuation before publishing")
        wire.answer(wire.command(0x40)!, Array(song.dropFirst(12)), fragment: 3, pdu: 0x20)
        check(phone.currentTrack?.title == "Song", "vendor continuation publishes complete metadata")
        artworkWire.onImage?("1000001",imageData)
        check(phone.currentTrack?.artwork == nil, "late previous-song cover cannot restore artwork after track change")
        wire.answer(wire.command(0x30)!, unknown)
        check(phone.playbackState == .stopped, "unknown phone position stops interpolation")
        time = time.addingTimeInterval(1)
        phone.updatePlayerState()
        wire.answer(wire.command(0x30)!, [0,0,0,0,0,0,0x30,0x39,1])
        check(abs(phone.playbackTime - 12.345) < 0.15, "zero duration does not clamp valid position to zero")
        let more = wire.sent.count
        phone.updatePlayerState()
        check(wire.sent.count == more, "parallel refresh requests are throttled")
        time = time.addingTimeInterval(9)
        phone.updatePlayerState()
        check(!phone.isConnected && phone.currentTrack == nil && phone.playbackState == .stopped, "missing status times out and clears all lyric state")
        check(phone.savedAddress != nil, "disconnect preserves chosen phone for reconnect")
        phone.disconnect()
        wire.answer(nextMetadata, song)
        check(phone.currentTrack == nil, "late disconnected data is ignored")
        phone.setActive(false)
        check(!phone.isConnected && !phone.isConnecting, "local player selection deactivates phone")
        // Supported metadata without status must not keep an invalid clock alive.
        phone.connect(address: "00-00-00-00-00-01", name: "Test Phone"); wire.onOpen?()
        time = time.addingTimeInterval(9)
        wire.answer(wire.command(0x20)!, song)
        phone.updatePlayerState()
        check(!phone.isConnected, "metadata-only responses cannot mask a missing position service")
        phone.connect(address: "00-00-00-00-00-01", name: "Test Phone"); wire.onOpen?()
        wire.answer(wire.command(0x20)!, [0], code: 0x08)
        check(!phone.isConnected && phone.currentTrack == nil, "unsupported essential command fails with empty source")
        phone.connect(address: "00-00-00-00-00-01", name: "Test Phone"); wire.onOpen?()
        wire.answer(wire.command(0x20)!, song)
        wire.answer(wire.command(0x30)!, playing)
        time = time.addingTimeInterval(5); phone.updatePlayerState()
        let oldPosition = wire.command(0x30)!
        wire.answer(wire.command(0x20)!, [2], code: 0x0a)
        check(phone.isConnected && phone.currentTrack == nil && phone.playbackTime == 0, "temporary queue-transition rejection retains channel and clears old song")
        wire.answer(oldPosition, playing)
        check(phone.playbackTime == 0, "position from before rejected queue transition cannot resume stale lyrics")
        time = time.addingTimeInterval(1); phone.updatePlayerState()
        wire.answer(wire.command(0x20)!, [2], code: 0x0a)
        wire.answer(wire.command(0x30)!, playing)
        time = time.addingTimeInterval(7); phone.updatePlayerState()
        check(phone.isConnected && phone.currentTrack == nil, "repeated metadata rejection without a track does not discard valid status or force reconnect")
        wire.answer(wire.command(0x20)!, song)
        wire.answer(wire.command(0x30)!, playing)
        check(phone.currentTrack?.title == "Song" && phone.playbackState.isPlaying, "queue transition recovers metadata and clock without reconnecting")
        time = time.addingTimeInterval(5); phone.updatePlayerState()
        let previousPosition = wire.command(0x30)!
        var changedSong = song; changedSong[9] = 0x4c // Long, same artist/album
        wire.answer(wire.command(0x20)!, changedSong)
        check(phone.currentTrack?.title == "Long" && phone.currentTrack?.duration == nil && phone.playbackTime == 0, "poll-detected song change discards old duration and clock without notifications")
        wire.answer(previousPosition, playing)
        check(phone.playbackTime == 0, "late previous-song status is ignored after poll-detected transition")
        wire.answer(wire.command(0x30)!, [0,3,0x0d,0x40,0,0,0x03,0xe8,1]) // 200 s, 1 s
        check(phone.currentTrack?.duration == 200 && abs(phone.playbackTime - 1) < 0.15, "poll-detected song uses freshly requested duration and position")
        phone.disconnect()
        phone.setActive(true); wire.onOpen?()
        wire.answer(wire.command(0x30)!, paused)
        let attempts = wire.addresses.count
        wire.onClose?("fixture disconnect")
        RunLoop.main.run(until: Date().addingTimeInterval(3.15))
        check(wire.addresses.count == attempts + 1 && phone.isConnecting, "active phone reconnects after transport disconnect")
        wire.onOpen?(); wire.onClose?("fixture disconnect")
        phone.disconnect()
        let stoppedAttempts = wire.addresses.count
        RunLoop.main.run(until: Date().addingTimeInterval(3.15))
        check(wire.addresses.count == stoppedAttempts, "manual disconnect cancels scheduled reconnect")
        phone.setActive(false)
        // Keep fallback latency separate from the one-second position clock.
        let fastWire = Wire(), fastArt = ArtworkWire()
        var fastTime = Date()
        let fastPhone = PhonePlayer(transport: fastWire, coverArt: fastArt, preferences: prefs, now: { fastTime })
        fastPhone.connect(address: "00-00-00-00-00-01", name: "Test Phone"); fastWire.onOpen?()
        let firstMeta = fastWire.command(0x20)!, firstStatus = fastWire.command(0x30)!
        fastWire.answer(firstMeta, Array(coveredSong)); fastWire.answer(firstStatus, playing)
        fastArt.onImage?("1000001", imageData)
        fastTime = fastTime.addingTimeInterval(0.25); fastPhone.updatePlayerState()
        check(fastWire.command(0x20) != firstMeta, "quarter-second fallback queries fresh song metadata")
        check(fastWire.command(0x30) == firstStatus, "faster metadata checks do not multiply position requests")
        let pendingMeta = fastWire.command(0x20)!
        fastTime = fastTime.addingTimeInterval(0.25); fastPhone.updatePlayerState()
        check(fastWire.command(0x20) == pendingMeta, "slow metadata replies retain one pending query")
        fastWire.answer(pendingMeta, Array(coveredSong))
        fastTime = fastTime.addingTimeInterval(0.5); fastPhone.updatePlayerState()
        let oldSongMeta = fastWire.command(0x20)!
        // The new duration arrives before the new song's title or artwork.
        fastWire.answer(fastWire.command(0x30)!, [0,3,0xa9,0x80,0,0,0x03,0xe8,1]) // 240 s, 1 s
        check(fastPhone.currentTrack == nil, "changed duration clears prior song and cover while metadata is pending")
        fastArt.onImage?("1000001", imageData); fastWire.answer(oldSongMeta, Array(coveredSong))
        check(fastPhone.currentTrack == nil, "old metadata and image cannot refill the loading placeholder")
        fastWire.answer(fastWire.command(0x20)!, changedSong)
        check(fastPhone.currentTrack?.title == "Long" && fastPhone.currentTrack?.duration == 240 && fastPhone.currentTrack?.artwork == nil, "new song publishes fresh duration with cover placeholder")
        fastPhone.disconnect()
        let notifyWire = Wire()
        var notifyTime = Date()
        let notifyPhone = PhonePlayer(transport: notifyWire, coverArt: ArtworkWire(), preferences: prefs, now: { notifyTime })
        notifyPhone.connect(address: "00-00-00-00-00-01", name: "Test Phone"); notifyWire.onOpen?()
        notifyWire.answer(notifyWire.command(0x20)!, song)
        notifyWire.answer(notifyWire.command(0x30)!, playing)
        notifyWire.answer(notifyWire.command(0x10)!, [3,4,1,2,9,11])
        let notifiedTrack = notifyWire.command(0x31, event: 2)!
        notifyWire.answer(notifiedTrack, [2,0,0,0,0,0,0,0,1], code: 0x0f)
        notifyWire.answer(notifyWire.command(0x31, event: 9)!, [9], code: 0x0f)
        notifyWire.answer(notifyWire.command(0x31, event: 11)!, [11,0,1,0,1], code: 0x0f)
        let settledMetadata = notifyWire.command(0x20)!
        notifyTime = notifyTime.addingTimeInterval(1); notifyPhone.updatePlayerState()
        check(notifyWire.command(0x20) == settledMetadata, "accepted track notification stops steady-song metadata polling")
        let notifiedState = notifyWire.command(0x31, event: 1)!
        notifyWire.answer(notifiedState, [1,1], code: 0x0f)
        notifyWire.answer(notifiedState, [1,2], code: 0x0d)
        notifyWire.answer(notifyWire.command(0x31, event: 1)!, [1,2], code: 0x0f)
        check(!notifyPhone.playbackState.isPlaying && notifyPhone.isConnected, "pause notification freezes clock before GetPlayStatus reply")
        notifyWire.answer(notifyWire.command(0x30)!, Array(playing.dropLast()) + [2])
        let pausedStatus = notifyWire.command(0x30)!
        notifyTime = notifyTime.addingTimeInterval(10); notifyPhone.updatePlayerState()
        check(notifyPhone.isConnected && notifyWire.command(0x30) == pausedStatus, "quiet paused phone with status subscription needs no polling or false watchdog disconnect")
        let sendBoundary = notifyWire.sent.count
        notifyWire.answer(notifiedTrack, [2,0,0,0,0,0,0,0,2], code: 0x0d)
        let afterChange = Array(notifyWire.sent.dropFirst(sendBoundary))
        check(afterChange.first?[9] == 0x31 && afterChange.contains(where: { $0[9] == 0x20 }), "track notification renews subscription before fetching new metadata")
        check(notifyPhone.currentTrack == nil, "notification-first path clears old song before loading")
        notifyWire.answer(notifyWire.command(0x20)!, changedSong)
        notifyWire.answer(notifyWire.command(0x30)!, playing)
        let playerChange = notifyWire.command(0x31, event: 11)!
        notifyWire.answer(playerChange, [11,0,1,0,1], code: 0x0f)
        notifyWire.answer(playerChange, [11,0,2,0,2], code: 0x0d)
        check(notifyPhone.currentTrack == nil && notifyPhone.playbackTime == 0, "addressed-player notification clears the previous app song and clock")
        notifyWire.answer(notifyWire.command(0x20)!, song)
        notifyWire.answer(notifyWire.command(0x30)!, playing)
        let refusedTrack = notifyWire.command(0x31, event: 2)!
        notifyWire.answer(refusedTrack, [1], code: 0x0a)
        let beforeFallback = notifyWire.command(0x20)!
        notifyTime = notifyTime.addingTimeInterval(0.25); notifyPhone.updatePlayerState()
        check(notifyWire.command(0x20) != beforeFallback, "rejected track subscription restores short metadata fallback")
        let refusedRegistration = notifyWire.command(0x31, event: 2)!
        notifyTime = notifyTime.addingTimeInterval(0.25); notifyPhone.updatePlayerState()
        check(notifyWire.command(0x31, event: 2) == refusedRegistration, "rejected notification retries are bounded instead of flooding the phone")
        notifyPhone.disconnect()
        let positionWire = Wire()
        var positionTime = Date()
        let positionPhone = PhonePlayer(transport: positionWire, coverArt: ArtworkWire(), preferences: prefs, now: { positionTime })
        positionPhone.connect(address: "00-00-00-00-00-01", name: "Test Phone"); positionWire.onOpen?()
        positionWire.answer(positionWire.command(0x20)!, song)
        positionWire.answer(positionWire.command(0x30)!, playing)
        positionWire.answer(positionWire.command(0x10)!, [3,3,1,2,5])
        positionWire.answer(positionWire.command(0x31, event: 2)!, [2,0,0,0,0,0,0,0,1], code: 0x0f)
        positionWire.answer(positionWire.command(0x31, event: 1)!, [1,1], code: 0x0f)
        positionWire.answer(positionWire.command(0x30)!, playing)
        let positionEvent = positionWire.command(0x31, event: 5)!
        positionWire.answer(positionEvent, [5,0,0,0x30,0x39], code: 0x0f)
        let stableStatus = positionWire.command(0x30)!
        positionTime = positionTime.addingTimeInterval(1); positionPhone.updatePlayerState()
        check(positionWire.command(0x30) == stableStatus, "accepted position and status notifications avoid redundant progress queries")
        positionWire.answer(positionEvent, [5,0,0,0xea,0x60], code: 0x0d)
        check(abs(positionPhone.playbackTime - 60) < 0.15, "position notification applies phone seek directly without GetPlayStatus round trip")
        positionTime = positionTime.addingTimeInterval(4); positionPhone.updatePlayerState()
        check(positionWire.command(0x30) != stableStatus, "stalled periodic position notifications trigger bounded status recovery")
        positionPhone.disconnect()
        let coverRaceWire = Wire(), coverRaceArt = ArtworkWire()
        var coverRaceTime = Date()
        let coverRacePhone = PhonePlayer(transport: coverRaceWire, coverArt: coverRaceArt, preferences: prefs, now: { coverRaceTime })
        coverRacePhone.connect(address: "00-00-00-00-00-01", name: "Test Phone"); coverRaceWire.onOpen?()
        let preSessionMetadata = coverRaceWire.command(0x20)!
        coverRaceWire.answer(coverRaceWire.command(0x30)!, playing)
        coverRaceWire.answer(coverRaceWire.command(0x10)!, [3,1,2])
        coverRaceWire.answer(coverRaceWire.command(0x31,event:2)!, [2,0,0,0,0,0,0,0,1], code:0x0f)
        coverRaceArt.onReady?()
        check(coverRaceWire.command(0x20) == preSessionMetadata, "OBEX ready does not duplicate an in-flight metadata transaction")
        coverRaceWire.answer(preSessionMetadata, Array(coveredSong))
        let postSessionMetadata = coverRaceWire.command(0x20)!
        check(postSessionMetadata != preSessionMetadata, "OBEX ready retains a forced refresh after the older transaction completes")
        check(coverRaceArt.handles.isEmpty && coverRacePhone.currentTrack?.title == "Song", "pre-session response updates song but cannot supply the new session image handle")
        coverRaceWire.answer(postSessionMetadata, Array(coveredSong))
        check(coverRaceArt.handles == ["1000001"], "post-session metadata supplies the valid thumbnail handle")
        coverRaceArt.onReady?()
        let expiringMetadata = coverRaceWire.command(0x20)!
        coverRaceArt.onReady?()
        coverRaceTime = coverRaceTime.addingTimeInterval(3.5); coverRacePhone.updatePlayerState()
        check(coverRaceWire.command(0x20) != expiringMetadata, "forced cover refresh survives timeout even with accepted track notifications")
        let firstRefreshRetry = coverRaceWire.command(0x20)!
        coverRaceTime = coverRaceTime.addingTimeInterval(3.5); coverRacePhone.updatePlayerState()
        coverRaceWire.answer(coverRaceWire.command(0x30)!, playing)
        check(coverRaceWire.command(0x20) != firstRefreshRetry, "session metadata timeout retries despite a healthy track subscription")
        coverRaceTime = coverRaceTime.addingTimeInterval(3.5); coverRacePhone.updatePlayerState()
        coverRaceWire.answer(coverRaceWire.command(0x30)!, playing)
        let finalRefreshRetry = coverRaceWire.command(0x20)!
        coverRaceTime = coverRaceTime.addingTimeInterval(3.5); coverRacePhone.updatePlayerState()
        check(coverRaceWire.command(0x20) == finalRefreshRetry, "session metadata retries have a finite budget")
        coverRacePhone.disconnect()
        let uidWire = Wire(), uidArt = ArtworkWire()
        let uidPhone = PhonePlayer(transport: uidWire, coverArt: uidArt, preferences: prefs)
        uidPhone.connect(address: "00-00-00-00-00-01", name: "Test Phone"); uidWire.onOpen?()
        uidWire.answer(uidWire.command(0x20)!, Array(coveredSong)); uidWire.answer(uidWire.command(0x30)!, playing)
        uidArt.onImage?("1000001",imageData)
        uidWire.answer(uidWire.command(0x10)!, [3,1,12])
        let uidEvent = uidWire.command(0x31,event:12)!
        uidWire.answer(uidEvent,[12,0,1],code:0x0f)
        check(uidArt.sessionRestarts == 0, "initial UID notification does not reset an uninvalidated session")
        uidWire.answer(uidEvent,[12,0,2],code:0x0d)
        check(uidArt.sessionRestarts == 1 && uidPhone.currentTrack?.artwork == nil, "UID change immediately clears image and requests OBEX session restart")
        uidWire.answer(uidWire.command(0x20)!,Array(coveredSong)); uidArt.onImage?("1000001",imageData)
        check(uidPhone.currentTrack?.artwork == nil, "same-text old handle cannot restore artwork while UID session resets")
        uidArt.onReady?(); uidWire.answer(uidWire.command(0x20)!,Array(coveredSong)); uidArt.onImage?("1000001",imageData)
        check(uidPhone.currentTrack?.artwork != nil, "reused handle becomes eligible only after new session and fresh metadata")
        uidPhone.disconnect()
        let capabilityWire = Wire()
        var capabilityTime = Date()
        let capabilityPhone = PhonePlayer(transport: capabilityWire, coverArt: ArtworkWire(), preferences: prefs, now: { capabilityTime })
        capabilityPhone.connect(address: "00-00-00-00-00-01", name: "Test Phone"); capabilityWire.onOpen?()
        let lostCapabilities = capabilityWire.command(0x10)!
        capabilityWire.answer(capabilityWire.command(0x30)!, playing)
        capabilityWire.answer(capabilityWire.command(0x20)!, song)
        capabilityTime = capabilityTime.addingTimeInterval(3.1); capabilityPhone.updatePlayerState()
        let retriedCapabilities = capabilityWire.command(0x10)!
        check(retriedCapabilities != lostCapabilities, "lost initial capability query retries before permanent polling fallback")
        capabilityWire.answer(lostCapabilities, [3,1,2])
        check(capabilityWire.command(0x31,event:2) == nil, "late expired capability reply cannot install subscriptions")
        capabilityWire.answer(retriedCapabilities, [3,1,2])
        check(capabilityWire.command(0x31,event:2) != nil, "retried capability reply starts track notification subscription")
        capabilityTime = capabilityTime.addingTimeInterval(3.1); capabilityPhone.updatePlayerState()
        check(capabilityWire.command(0x10) == retriedCapabilities, "successful capability query stops capability retries")
        capabilityPhone.disconnect()
        capabilityPhone.connect(address: "00-00-00-00-00-01", name: "Test Phone"); capabilityWire.onOpen?()
        for _ in 0..<4 {
            capabilityWire.answer(capabilityWire.command(0x30)!, playing)
            capabilityTime = capabilityTime.addingTimeInterval(3.1); capabilityPhone.updatePlayerState()
        }
        let boundedCapabilities = capabilityWire.command(0x10)
        capabilityWire.answer(capabilityWire.command(0x30)!, playing)
        capabilityTime = capabilityTime.addingTimeInterval(3.1); capabilityPhone.updatePlayerState()
        check(capabilityWire.command(0x10) == boundedCapabilities, "unsupported or unresponsive capability discovery has a finite attempt budget")
        capabilityPhone.disconnect()
        let fallbackWire = Wire(), fallbackArt = ArtworkWire()
        var fallbackTime = Date()
        let fallbackPhone = PhonePlayer(transport: fallbackWire, coverArt: fallbackArt, preferences: prefs, now: { fallbackTime })
        fallbackPhone.connect(address: "00-00-00-00-00-01", name: "Test Phone")
        fallbackWire.onOpen?()
        fallbackWire.answer(fallbackWire.command(0x20)!, song)
        fallbackWire.answer(fallbackWire.command(0x30)!, playing)
        check(!fallbackPhone.needsArtworkFallback, "no web fallback while Bluetooth capability discovery is pending")
        let fallbackKey = fallbackPhone.artworkFallbackKey!
        let fallbackImage = NSImage(data: imageData)!
        fallbackPhone.acceptArtworkFallback(fallbackImage, for: fallbackKey)
        check(fallbackPhone.currentTrack?.artwork == nil, "premature web result cannot bypass Bluetooth priority")
        fallbackArt.onState?(.unavailable)
        check(fallbackPhone.needsArtworkFallback, "confirmed unavailable cover channel permits web fallback")
        var fallbackLyricChanges = 0
        let fallbackObservation = fallbackPhone.currentTrackWillChange.sink { _ in fallbackLyricChanges += 1 }
        fallbackPhone.acceptArtworkFallback(fallbackImage, for: fallbackKey)
        check(fallbackPhone.currentTrack?.artwork === fallbackImage && !fallbackPhone.needsArtworkFallback, "web cover populates track without repeated lookup")
        check(fallbackLyricChanges == 1, "web artwork does not restart lyrics search")
        fallbackPhone.clearArtworkFallback()
        check(fallbackPhone.currentTrack?.artwork == nil && fallbackPhone.needsArtworkFallback, "disabling online covers clears only the fallback")
        fallbackPhone.acceptArtworkFallback(fallbackImage, for: fallbackKey)
        fallbackTime = fallbackTime.addingTimeInterval(1); fallbackPhone.updatePlayerState()
        fallbackWire.answer(fallbackWire.command(0x20)!, Array(coveredSong))
        fallbackArt.onImage?("1000001", imageData)
        check(fallbackPhone.currentTrack?.artwork != nil && fallbackPhone.currentTrack?.artwork !== fallbackImage, "late Bluetooth image supersedes online cover")
        fallbackPhone.clearArtworkFallback()
        check(fallbackPhone.currentTrack?.artwork != nil, "disabling web fallback preserves Bluetooth artwork")
        fallbackPhone.disconnect()
        check(!fallbackPhone.needsArtworkFallback && fallbackPhone.currentTrack == nil, "disconnect clears fallback and stops eligibility")
        fallbackPhone.connect(address: "00-00-00-00-00-01", name: "Test Phone"); fallbackWire.onOpen?()
        fallbackWire.answer(fallbackWire.command(0x20)!, song)
        fallbackArt.onState?(.unavailable)
        fallbackPhone.acceptArtworkFallback(fallbackImage, for: fallbackKey)
        check(fallbackPhone.currentTrack?.artwork == nil && fallbackPhone.artworkFallbackKey != fallbackKey, "reconnecting to the same song rejects the previous session result")
        let nextKey = fallbackPhone.artworkFallbackKey!
        fallbackPhone.acceptArtworkFallback(fallbackImage, for: nextKey)
        fallbackTime = fallbackTime.addingTimeInterval(1); fallbackPhone.updatePlayerState()
        var nextSong = song; nextSong[9] = 0x4c
        fallbackWire.answer(fallbackWire.command(0x20)!, nextSong)
        check(fallbackPhone.currentTrack?.artwork == nil, "track change immediately removes the prior online cover")
        fallbackPhone.acceptArtworkFallback(fallbackImage, for: nextKey)
        check(fallbackPhone.currentTrack?.artwork == nil, "late old-song web result is ignored")
        fallbackArt.onState?(.ready); fallbackArt.onReady?()
        check(!fallbackPhone.needsArtworkFallback, "ready image session waits for fresh handle metadata")
        fallbackWire.answer(fallbackWire.command(0x20)!, nextSong)
        check(fallbackPhone.needsArtworkFallback, "fresh metadata without an image handle permits fallback")
        fallbackObservation.cancel()
        fallbackPhone.disconnect()
        // Feature gate must stop real protocol work, including pending retries.
        let toggleSuite = "LyricsX.PhoneToggleProbe." + UUID().uuidString
        let togglePrefs = UserDefaults(suiteName: toggleSuite)!
        defer { togglePrefs.removePersistentDomain(forName: toggleSuite) }
        let toggleWire = Wire(), toggleArt = ArtworkWire()
        let toggled = PhonePlayer(transport: toggleWire, coverArt: toggleArt, preferences: togglePrefs)
        check(!toggled.isEnabled, "missing AVRCP preference defaults to disabled")
        toggled.setActive(true)
        check(toggleWire.addresses.isEmpty, "default-disabled source does not connect")
        toggled.setActive(false)
        toggled.setEnabled(true)
        toggled.remember(address: "00-00-00-00-00-02", name: "Saved Phone")
        toggled.setActive(true); toggleWire.onOpen?()
        toggleWire.answer(toggleWire.command(0x20)!, song)
        toggleWire.answer(toggleWire.command(0x30)!, playing)
        check(toggled.isConnected && toggled.currentTrack != nil, "toggle fixture starts connected with a song")
        toggled.setEnabled(false)
        check(togglePrefs.object(forKey: "PhoneBluetoothEnabled") as? Bool == false, "disabled AVRCP preference is persisted")
        check(!toggled.isConnected && !toggled.isConnecting && toggled.currentTrack == nil && !toggled.playbackState.isPlaying, "disabling clears phone playback and connection state")
        check(!toggled.isLoadingTrack && !toggled.isChangingTrack && toggled.artworkState == .unavailable, "disabling clears transitions and artwork")
        check(toggled.savedAddress == "00-00-00-00-00-02" && toggled.deviceName == "Saved Phone", "disabling preserves remembered device")
        let disabledStatus = toggled.statusMessage
        let beforeDisabledConnect = toggleWire.addresses.count
        let beforeDisabledPackets = toggleWire.sent.count
        let beforeDisabledArtwork = toggleArt.endpoints.count
        toggled.connect(address: "00-00-00-00-00-03", name: "Other Phone")
        toggleWire.onOpen?(); toggleWire.onStatus?("Late connecting status")
        toggleArt.onReady?(); toggleArt.onState?(.loaded)
        toggled.updatePlayerState(); toggled.skipToNextItem()
        check(toggleWire.addresses.count == beforeDisabledConnect && toggled.deviceName == "Saved Phone", "manual connect while disabled neither opens a worker nor overwrites device")
        check(!toggled.isConnected && toggled.statusMessage == disabledStatus, "late open and status cannot reactivate a disabled phone")
        check(toggleWire.sent.count == beforeDisabledPackets && toggleArt.endpoints.count == beforeDisabledArtwork, "disabled phone sends neither AVRCP commands nor cover connections")
        check(toggled.artworkState == .unavailable, "late cover callbacks are ignored while disabled")
        let restored = PhonePlayer(transport: Wire(), coverArt: ArtworkWire(), preferences: togglePrefs)
        check(!restored.isEnabled, "new player instance honors the persisted disabled preference")
        toggled.setEnabled(true)
        check(toggled.isEnabled && toggled.isConnecting && toggleWire.addresses.count == beforeDisabledConnect + 1, "enabling active phone reconnects saved device once")
        toggled.setEnabled(true)
        check(toggleWire.addresses.count == beforeDisabledConnect + 1, "repeated enabled value does not reconnect")
        check(togglePrefs.bool(forKey: "PhoneBluetoothEnabled"), "enabled AVRCP preference is persisted")
        toggleWire.onClose?("Synthetic dropped connection")
        toggled.setEnabled(false)
        let retryCount = toggleWire.addresses.count
        RunLoop.main.run(until: Date().addingTimeInterval(3.2))
        check(toggleWire.addresses.count == retryCount, "disabling cancels the scheduled reconnect")
        toggled.setActive(false); toggled.setEnabled(true)
        check(toggleWire.addresses.count == retryCount && !toggled.isConnecting, "enabling while a local source is selected does not connect")
        toggled.disconnect()
        print("\(count) checks passed")
    }
}
