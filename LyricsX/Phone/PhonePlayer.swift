import AppKit
import Combine
import MusicPlayer
import ImageIO

/// An AVRCP source: only control/metadata traffic is requested, never an audio profile.
final class PhonePlayer: ObservableObject, MusicPlayerProtocol, PlaybackTransitionSource {
    static let shared = PhonePlayer()
    static let preferenceIndex = 5
    @Published private(set) var currentTrack: MusicTrack?
    @Published private(set) var playbackState: PlaybackState = .stopped
    @Published private(set) var statusMessage = NSLocalizedString("Choose a paired phone to connect.", comment: "Phone source")
    @Published private(set) var isEnabled = false
    @Published private(set) var isConnected = false
    @Published private(set) var isConnecting = false
    @Published private(set) var artworkState: PhoneArtworkState = .unavailable
    @Published private(set) var isChangingTrack = false
    // Loading metadata can outlive the short automatic-selection grace period.
    // Only an actual reply or disconnect can resolve the menu's loading state.
    @Published private(set) var isLoadingTrack = false
    private var transitionDeadline: Date?
    private struct Query {
        let pdu: UInt8
        let parameters: [UInt8]
        let event: UInt8?
        let expected: UInt8
        let command: UInt8
        let coverRefresh: Bool
    }
    // Each query kind has one wire transaction; newer demand is coalesced.
    // Notifications keep their own long-lived transactions.
    private var queuedQueries: [UInt8: Query] = [:]
    private var commands: [UInt8] = []
    private var sendingCommand = false
    private var lastTrackUID: Data?
    private var skippedTrackID: String?
    private var skipDeadline: Date?
    private var previousMayRestart = false
    private var skipConfirmation: (origin: String?, deadline: Date)?
    private let transport: PhoneTransport
    private let coverArt: PhoneArtworkTransport
    private let preferences: UserDefaults
    private let now: () -> Date
    private var active = false
    private var reconnectSuppressed = false
    private var pollTimer: Timer?
    private var retryTimer: Timer?
    private var assembler = AVCTPAssembler()
    private var continuation = Data()
    private var continuationEpoch = 0
    private var epoch = 0
    private var label: UInt8 = 0
    private struct Pending { let pdu: UInt8; let event: UInt8?; let epoch: Int; var expires: Date?; var coverRefresh = false }
    private var pending: [UInt8: Pending] = [:]
    private var lastStatusResponse = Date.distantPast
    private var lastPoll = Date.distantPast
    private var lastStatusPoll = Date.distantPast
    private var knownDuration: TimeInterval?
    private var lastRemotePosition: TimeInterval?
    private var lastMetadata = Date.distantPast
    private var remoteState: UInt8 = 0
    private var retryDelay: TimeInterval = 3
    private var capabilitiesKnown = false
    private var capabilityAttemptsRemaining = 3
    private var capabilityRetryAfter = Date.distantPast
    private var supportedEvents = Set<UInt8>()
    private var registeredEvents = Set<UInt8>()
    private var notificationRetryAfter: [UInt8: Date] = [:]
    private var lastPositionNotification = Date.distantPast
    private static let observedEvents: [UInt8] = [1, 2, 5, 9, 10, 11, 12]
    private var metadata: [UInt32: String] = [:]
    private var artwork: NSImage?
    private var fallbackArtwork: NSImage?
    private var coverMissingHandle = false

    /// Includes the connection/track generation so late results cannot survive A → B → A.
    var artworkFallbackKey: String? {
        guard isConnected, let track = currentTrack else { return nil }
        return "\(epoch):\(track.id)"
    }
    var isUsingArtworkFallback: Bool { artwork == nil && fallbackArtwork != nil }
    var needsArtworkFallback: Bool {
        isConnected && currentTrack != nil && artwork == nil && fallbackArtwork == nil
            && (artworkState == .unavailable || coverMissingHandle)
    }
    func acceptArtworkFallback(_ image: NSImage, for key: String) {
        guard needsArtworkFallback, artworkFallbackKey == key else { return }
        fallbackArtwork = image
        rebuildTrack()
    }
    func clearArtworkFallback() {
        guard fallbackArtwork != nil else { return }
        fallbackArtwork = nil
        rebuildTrack()
    }
    private var requestedHandle: String?
    private var coverMetadataRefreshPending = false
    private var coverSessionWaiting = false
    private var coverMetadataRetries = 0

    var name: MusicPlayerName? { nil }
    var savedAddress: String? { preferences.string(forKey: "PhoneBluetoothAddress") }
    var deviceName: String { preferences.string(forKey: "PhoneBluetoothName") ?? NSLocalizedString("Phone", comment: "Phone source") }
    var autoReconnect: Bool {
        get { preferences.object(forKey: "PhoneAutoReconnect") as? Bool ?? true }
        set { preferences.set(newValue, forKey: "PhoneAutoReconnect"); if !newValue { retryTimer?.invalidate(); retryTimer = nil } }
    }
    // Duration and artwork updates refresh the menu via objectWillChange; they
    // must not cancel/restart the existing song's lyric search.
    var currentTrackWillChange: AnyPublisher<MusicTrack?, Never> { $currentTrack.removeDuplicates().eraseToAnyPublisher() }
    var playbackStateWillChange: AnyPublisher<PlaybackState, Never> { $playbackState.eraseToAnyPublisher() }
    var playbackTime: TimeInterval {
        get { lastRemotePosition == nil ? 0 : max(0, playbackState.time) }
        set { /* AVRCP has no interoperable absolute-position seek command. */ }
    }
    init(transport: PhoneTransport = PhoneBluetoothTransport(), coverArt: PhoneArtworkTransport? = nil, preferences: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        let coverArt = coverArt ?? PhoneCoverArt()
        self.transport = transport; self.coverArt = coverArt; self.preferences = preferences; self.now = now
        isEnabled = preferences.object(forKey: "PhoneBluetoothEnabled") as? Bool ?? false
        if !isEnabled { statusMessage = Self.disabledMessage }
        transport.onOpen = { [weak self] in self?.onMain { $0.opened() } }
        transport.onData = { [weak self] data in self?.onMain { $0.receive(data) } }
        transport.onStatus = { [weak self] message in self?.onMain { if $0.isEnabled { $0.statusMessage = message } } }
        transport.onClose = { [weak self] message in self?.onMain { $0.closed(message) } }
        coverArt.onReady = { [weak self] in self?.onMain { player in
            guard player.isEnabled, player.isConnected else { return }
            player.coverSessionWaiting = false
            player.coverMissingHandle = false
            player.requestedHandle = nil
            player.artwork = nil; player.metadata[8] = nil; player.rebuildTrack()
            // An older metadata request may still be in flight. Keep this demand
            // until a new request is actually sent after OBEX becomes ready.
            player.coverMetadataRefreshPending = true
            player.coverMetadataRetries = 2
            player.lastMetadata = .distantPast; player.requestMetadata()
        } }
        coverArt.onState = { [weak self] state in self?.onMain { if $0.isEnabled { $0.artworkState = state } } }
        coverArt.onImage = { [weak self] handle, data in self?.onMain { player in
            guard player.isConnected, !player.coverSessionWaiting, player.requestedHandle == handle, player.metadata[8] == handle,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int, width > 0, width <= 512,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int, height > 0, height <= 512,
                  let image = NSImage(data: data) else { return }
            player.artwork = image; player.artworkState = .loaded; player.rebuildTrack()
        } }
    }
    deinit { pollTimer?.invalidate(); retryTimer?.invalidate(); transport.disconnect(); coverArt.disconnect() }
    private static var disabledMessage: String {
        NSLocalizedString("Bluetooth AVRCP is disabled. Enable it in Labs.", comment: "Disabled phone source")
    }
    func setEnabled(_ value: Bool) {
        onMain { player in
            guard player.isEnabled != value else { return }
            player.isEnabled = value
            player.preferences.set(value, forKey: "PhoneBluetoothEnabled")
            if !value {
                player.disconnect()
            } else {
                player.statusMessage = NSLocalizedString("Choose a paired phone to connect.", comment: "Phone source")
                if player.active, let address = player.savedAddress {
                    player.connect(address: address, name: player.deviceName)
                }
            }
        }
    }
    func setActive(_ value: Bool) {
        onMain { player in
            guard player.active != value else { return }
            player.active = value
            if value {
                player.reconnectSuppressed = false
                if let address = player.savedAddress { player.connect(address: address, name: player.deviceName) }
            } else { player.disconnect() }
        }
    }
    func remember(address: String, name: String) {
        preferences.set(address, forKey: "PhoneBluetoothAddress")
        preferences.set(name, forKey: "PhoneBluetoothName")
    }
    func connect(address: String, name: String) {
        onMain { player in
            guard player.isEnabled else { return }
            player.reset()
            player.transport.disconnect()
            player.remember(address: address, name: name)
            player.reconnectSuppressed = false
            player.isConnecting = true
            player.statusMessage = NSLocalizedString("Connecting to phone…", comment: "Phone source")
            player.transport.connect(address: address)
        }
    }
    func disconnect() {
        onMain { player in
            player.reconnectSuppressed = true
            player.reset(); player.transport.disconnect()
            player.statusMessage = player.isEnabled
                ? NSLocalizedString("Phone disconnected.", comment: "Phone source") : Self.disabledMessage
        }
    }
    private func reset() {
        endTrackTransition()
        isLoadingTrack = false
        skippedTrackID = nil; skipDeadline = nil; previousMayRestart = false; skipConfirmation = nil
        pollTimer?.invalidate(); pollTimer = nil
        retryTimer?.invalidate(); retryTimer = nil
        queuedQueries.removeAll(); commands.removeAll(); lastTrackUID = nil
        pending.removeAll(); assembler.reset(); continuation.removeAll(); epoch += 1
        supportedEvents.removeAll(); registeredEvents.removeAll(); notificationRetryAfter.removeAll()
        capabilitiesKnown = false; capabilityAttemptsRemaining = 3; capabilityRetryAfter = .distantPast
        lastPositionNotification = .distantPast
        metadata.removeAll(); lastMetadata = .distantPast
        coverArt.disconnect(); artworkState = .unavailable; artwork = nil; fallbackArtwork = nil; coverMissingHandle = false; requestedHandle = nil
        coverMetadataRefreshPending = false
        coverMetadataRetries = 0
        coverSessionWaiting = false
        knownDuration = nil; lastRemotePosition = nil; lastPoll = .distantPast; lastStatusPoll = .distantPast
        isConnected = false; isConnecting = false; remoteState = 0
        currentTrack = nil; playbackState = .stopped
    }
    private func opened() {
        guard isEnabled else { transport.disconnect(); return }
        isConnecting = false; isConnected = true
        isLoadingTrack = true
        artworkState = .connecting
        statusMessage = NSLocalizedString("Checking phone playback information…", comment: "Phone source")
        lastStatusResponse = now()
        requestCapabilities()
        poll()
        if let address = savedAddress { coverArt.connect(address: address, psm: transport.coverPSM) }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.poll() }
        pollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }
    private func closed(_ message: String) {
        trace("channel closed: " + message)
        reset(); statusMessage = isEnabled ? message : Self.disabledMessage
        guard isEnabled, active, !reconnectSuppressed, autoReconnect, savedAddress != nil else { return }
        let timer = Timer(timeInterval: retryDelay, repeats: false) { [weak self] _ in
            guard let self = self, let address = self.savedAddress, self.isEnabled, self.active, !self.reconnectSuppressed else { return }
            self.connect(address: address, name: self.deviceName)
        }
        retryDelay = min(30, retryDelay * 2)
        retryTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func fail(_ message: String) { transport.disconnect(); closed(message) }
    func updatePlayerState() { onMain { $0.poll() } }
    private func poll() {
        guard isConnected else { return }
        let timestamp = now()
        if let deadline = transitionDeadline, timestamp >= deadline { endTrackTransition() }
        guard timestamp.timeIntervalSince(lastPoll) >= 0.18 else { return }
        lastPoll = timestamp
        for transaction in pending.values where transaction.expires.map({ $0 <= timestamp }) ?? false {
            if isChangingTrack, transaction.pdu == 0x30 { lastStatusPoll = .distantPast }
            if transaction.coverRefresh, coverMetadataRetries > 0 {
                coverMetadataRetries -= 1; coverMetadataRefreshPending = true
            }
            if transaction.pdu == 0x31, let event = transaction.event {
                registeredEvents.remove(event)
                notificationRetryAfter[event] = timestamp.addingTimeInterval(3)
                trace("notification registration timeout event=" + String(event))
            }
        }
        for (label, transaction) in pending where transaction.expires.map({ $0 <= timestamp }) ?? false {
            trace("timeout label=\(label) pdu=\(transaction.pdu) epoch=\(transaction.epoch)")
        }
        pending = pending.filter { $0.value.expires.map { $0 > timestamp } ?? true }
        drainCommands()
        drainQueries()
        requestCapabilities()
        let needsStatus = currentTrack == nil || !registeredEvents.contains(1)
            || ([UInt8(1), 3, 4].contains(remoteState) && (!registeredEvents.contains(5)
                || timestamp.timeIntervalSince(lastPositionNotification) > 3))
        if needsStatus, timestamp.timeIntervalSince(lastStatusResponse) > 8 {
            fail(NSLocalizedString("The phone is not sharing playback information.", comment: "Phone source")); return
        }
        if needsStatus, timestamp.timeIntervalSince(lastStatusPoll) >= 0.9, request(pdu: 0x30) { lastStatusPoll = timestamp }
        for event in Self.observedEvents where supportedEvents.contains(event)
            && !registeredEvents.contains(event)
            && timestamp >= (notificationRetryAfter[event] ?? .distantPast) { register(event: event) }
        // Once the phone accepts track notifications, a steady song needs no
        // repeated metadata queries. Loading and failed registrations keep the
        // existing short fallback, so old lyrics never stand in for a new track.
        if (coverMetadataRefreshPending || !registeredEvents.contains(2) || currentTrack == nil), timestamp.timeIntervalSince(lastMetadata) >= 0.2 { requestMetadata() }
    }
    private func requestCapabilities() {
        guard !capabilitiesKnown, capabilityAttemptsRemaining > 0, now() >= capabilityRetryAfter else { return }
        if request(pdu: 0x10, parameters: [3]) {
            capabilityAttemptsRemaining -= 1
            capabilityRetryAfter = now().addingTimeInterval(3)
        }
    }
    private func nextLabel() -> UInt8? {
        for _ in 0..<16 {
            label = (label + 1) & 15
            if pending[label] == nil { return label }
        }
        return nil
    }
    @discardableResult private func request(pdu: UInt8, parameters: [UInt8] = [], event: UInt8? = nil, expected: UInt8? = nil, command: UInt8 = 1, coverRefresh: Bool = false) -> Bool {
        let expected = expected ?? pdu
        guard isConnected else { return false }
        let query = Query(pdu: pdu, parameters: parameters, event: event, expected: expected,
                          command: command, coverRefresh: coverRefresh)
        if [UInt8(0x20), 0x30].contains(expected), pdu != 0x40 {
            if let active = pending.values.first(where: { $0.pdu == expected }), active.epoch == epoch {
                return false
            }
            // A previous generation keeps its label until reply/timeout. Never
            // let a late reply match a newly reused label after rapid skipping.
            if queuedQueries[expected]?.coverRefresh != true { queuedQueries[expected] = query }
            drainQueries()
            return true
        }
        return sendQuery(query)
    }
    @discardableResult private func sendQuery(_ query: Query) -> Bool {
        guard !pending.values.contains(where: { $0.pdu == query.expected && $0.event == query.event }),
              let label = nextLabel() else { return false }
        pending[label] = Pending(pdu: query.expected, event: query.event, epoch: epoch,
                                 expires: now().addingTimeInterval(2), coverRefresh: query.coverRefresh)
        trace(String(format: "send pdu=%02x label=%d epoch=%d event=%d", query.pdu, label, epoch, query.event.map(Int.init) ?? -1))
        transport.send(AVRCPCodec.vendor(label: label, pdu: query.pdu, parameters: query.parameters, command: query.command))
        return true
    }
    private func drainQueries() {
        guard isConnected, commands.isEmpty, !sendingCommand,
              !pending.values.contains(where: { $0.pdu == 0x7c }) else { return }
        // Metadata has priority; status is independent and must not gate title.
        for pdu: UInt8 in [0x20, 0x30] {
            guard let query = queuedQueries[pdu], !pending.values.contains(where: { $0.pdu == pdu }) else { continue }
            queuedQueries[pdu] = nil
            if !sendQuery(query) { queuedQueries[pdu] = query }
        }
    }
    private func requestMetadata() {
        if request(pdu: 0x20, parameters: Array(repeating: 0, count: 9), coverRefresh: coverMetadataRefreshPending) {
            lastMetadata = now(); coverMetadataRefreshPending = false
        }
    }
    private func register(event: UInt8) {
        request(pdu: 0x31, parameters: [event, 0, 0, 0, 1], event: event, command: 3)
    }
    private func receive(_ raw: Data) {
        let packets = AVRCPCodec.controlPackets(raw)
        if packets.count > 1 { trace("split receive batch bytes=\(raw.count) frames=\(packets.count)") }
        for packet in packets { receivePacket(packet) }
    }
    private func receivePacket(_ raw: Data) {
        guard isConnected else { return }
        trace("receive raw bytes=\(raw.count) label=\((raw.first ?? 0) >> 4)")
        // Decline commands for unsupported Target functionality; this endpoint is a Controller.
        if let reply = AVRCPCodec.controllerReply(raw) { transport.send(reply); return }
        guard let assembled = assembler.receive(raw) else { return }
        let avc = [UInt8](assembled)
        if avc.count == 8, avc[1...2] == [0x11, 0x0e], avc[4] == 0x48, avc[5] == 0x7c, avc[7] == 0,
           let transaction = pending[avc[0] >> 4], transaction.pdu == 0x7c, transaction.event == avc[6] {
            pending[avc[0] >> 4] = nil
            trace("command ack operation=\(avc[6]) code=\(avc[3])")
            drainCommands(); drainQueries()
            return
        }
        guard let response = AVRCPCodec.response(assembled) else { trace("drop malformed response"); return }
        guard let transaction = pending[response.label], transaction.pdu == response.pdu else {
            trace("drop unmatched response label=\(response.label) pdu=\(response.pdu)"); return
        }
        pending[response.label] = nil
        defer { drainCommands(); drainQueries() }
        guard transaction.epoch == epoch else {
            trace("drop superseded response epoch=\(transaction.epoch) current=\(epoch)"); return
        }
        defer {
            if response.pdu == 0x20, coverMetadataRefreshPending { requestMetadata() }
        }
        if response.pdu == 0x31 || !response.successful || PhoneDiagnostics.enabled {
            trace(String(format: "reply pdu=%02x code=%02x epoch=%d event=%d", response.pdu, response.code, epoch, transaction.event.map(Int.init) ?? -1))
        }
        guard response.successful else {
            if response.pdu == 0x10, response.code == 8 { capabilityAttemptsRemaining = 0 }
            if response.pdu == 0x31, let event = transaction.event {
                registeredEvents.remove(event)
                notificationRetryAfter[event] = now().addingTimeInterval(3)
            }
            if [0x20, 0x30].contains(response.pdu), response.code == 8 {
                fail(NSLocalizedString("The phone does not support song information and playback position.", comment: "Phone source"))
            } else if [0x20, 0x30].contains(response.pdu) {
                // A player can temporarily reject current-element requests while
                // replacing its queue item. Keep the control channel and retry;
                // the status watchdog still detects a genuinely unavailable service.
                if currentTrack != nil { invalidateTrack() }
            }
            return
        }
        var parameters = response.parameters
        if response.fragment != 0 {
            guard response.pdu == 0x20 else { return }
            if response.fragment == 1 { continuation = parameters; continuationEpoch = epoch }
            else {
                guard continuationEpoch == epoch, !continuation.isEmpty else { return }
                continuation.append(parameters)
            }
            guard continuation.count <= 65536 else { continuation.removeAll(); return }
            if response.fragment != 3 { request(pdu: 0x40, parameters: [0x20], expected: 0x20, command: 0, coverRefresh: transaction.coverRefresh); return }
            parameters = continuation; continuation.removeAll()
        }
        switch response.pdu {
        case 0x10:
            let b = [UInt8](parameters)
            if b.count >= 2, b[0] == 3, b.count == 2 + Int(b[1]) {
                capabilitiesKnown = true
                supportedEvents = Set(b.dropFirst(2))
                trace("supported notification events: " + supportedEvents.sorted().map(String.init).joined(separator: ","))
                for event in Self.observedEvents where supportedEvents.contains(event) { register(event: event) }
            }
        case 0x20:
            guard var values = AVRCPCodec.attributes(parameters) else { trace("invalid attribute response"); return }
            if let skippedTrackID = skippedTrackID, let deadline = skipDeadline,
               now() < deadline, trackID(for: values) == skippedTrackID {
                // A command acknowledgement does not mean the phone has
                // replaced its queue item yet. Retry instead of republishing it.
                trace("ignore pre-skip metadata while awaiting replacement")
                return
            }
            // A queue replacement may briefly return an empty element while
            // playback is still active. It is not evidence of an empty player.
            if (values[1] ?? "").isEmpty, isLoadingTrack, [UInt8(1), 3, 4].contains(remoteState) {
                trace("defer empty metadata during active playback")
                return
            }
            skippedTrackID = nil; skipDeadline = nil
            trace("attribute ids: " + values.keys.sorted().map(String.init).joined(separator: ","))
            // Handles from a request sent before the new OBEX session are not
            // eligible for that session; title/artist can still update normally.
            if coverMetadataRefreshPending || coverSessionWaiting { values[8] = nil }
            if !metadata.isEmpty, [UInt32(1), 2, 3].contains(where: { metadata[$0] != values[$0] }) {
                // Devices without track-change notifications are detected by polling.
                // Do not attach the previous song's duration/position to the new title.
                trace("track changed via metadata poll")
                invalidateTrack()
                request(pdu: 0x30)
            }
            coverMissingHandle = values[8] == nil && artworkState == .ready
                && !coverMetadataRefreshPending && !coverSessionWaiting
            // A status reply immediately after a skip can still describe the
            // old song. Prefer the new element's own duration and discard that
            // old clock, rather than clearing the new title on the next status.
            if isLoadingTrack, let milliseconds = values[7].flatMap(Double.init), milliseconds.isFinite, milliseconds > 0 {
                let duration = milliseconds / 1000
                if let knownDuration = knownDuration, knownDuration != duration { lastRemotePosition = nil }
                knownDuration = duration
            }
            metadata = values; rebuildTrack()
            isLoadingTrack = false
            if values[8] != requestedHandle {
                artwork = nil; requestedHandle = values[8]; rebuildTrack()
                if let handle = requestedHandle { coverArt.fetch(handle: handle) }
            }
        case 0x30:
            guard let status = AVRCPCodec.status(parameters) else { return }
            lastStatusResponse = now(); retryDelay = 3
            apply(status)
        case 0x31:
            let b = [UInt8](parameters)
            guard let event = b.first, event == transaction.event,
                  [0x0f, 0x0d].contains(response.code),
                  b.count == (event == 1 ? 2 : event == 2 ? 9 : event == 5 || event == 11 ? 5 : event == 12 ? 3 : event == 9 || event == 10 ? 1 : 0) else {
                if let event = transaction.event {
                    registeredEvents.remove(event); notificationRetryAfter[event] = now().addingTimeInterval(3)
                }
                return
            }
            registeredEvents.insert(event); notificationRetryAfter[event] = nil
            if response.code == 0x0f {
                var transaction = transaction; transaction.expires = nil
                pending[response.label] = transaction
            }
            // Renew a one-shot notification before fetching dependent content.
            if response.code == 0x0d { register(event: event) }
            if (event == 2 || event == 11), response.code == 0x0d {
                let confirmsPublishedSkip = event == 2 && skipConfirmation.map {
                    now() <= $0.deadline && currentTrack != nil && currentTrack?.id != $0.origin
                } == true
                if event == 2 {
                    let uid = Data(b.dropFirst())
                    // Zero means "current element" without browsing, not a
                    // stable identity. Only deduplicate real nonzero UIDs.
                    if uid.contains(where: { $0 != 0 }), uid.contains(where: { $0 != 255 }), uid == lastTrackUID { return }
                    lastTrackUID = uid
                    // A duplicate of the previous song is not confirmation of
                    // this skip. Consume the association only after deduplication.
                    skipConfirmation = nil
                }
                if event == 11 { lastTrackUID = nil }
                trace("track changed via notification")
                // A notification confirms an in-progress skip, rather than
                // cancelling the queries already fetching its replacement.
                if !isLoadingTrack && !confirmsPublishedSkip { invalidateTrack() }
                if confirmsPublishedSkip { trace("late track notification verifies already published skip") }
                requestMetadata(); request(pdu: 0x30)
            } else if event == 1 {
                // Use the notification payload immediately rather than waiting
                // for an additional status round trip to pause/resume the UI.
                lastStatusResponse = now()
                apply(AVRCPCodec.Status(duration: knownDuration, position: lastRemotePosition == nil ? nil : playbackTime, state: b[1]))
                request(pdu: 0x30)
            } else if event == 5 {
                let value = b.dropFirst().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                lastPositionNotification = now(); lastStatusResponse = now()
                apply(AVRCPCodec.Status(duration: knownDuration, position: value == .max ? nil : Double(value) / 1000, state: remoteState))
            } else if response.code == 0x0d, event == 12 {
                // UIDs_CHANGED invalidates every image handle in the old OBEX
                // session, even if the next song reuses the same handle text.
                coverSessionWaiting = true
                artwork = nil; requestedHandle = nil; metadata[8] = nil; rebuildTrack()
                if artworkState != .unavailable { artworkState = .connecting }
                coverArt.restartSession()
                lastMetadata = .distantPast; requestMetadata()
            } else if response.code == 0x0d, event == 9 || event == 10 {
                lastMetadata = .distantPast; requestMetadata()
            }
        default: break
        }
    }
    private func invalidateTrack(renewSelectionGrace: Bool = false) {
        isLoadingTrack = true
        if !isChangingTrack || renewSelectionGrace {
            transitionDeadline = now().addingTimeInterval(2)
            isChangingTrack = true
        }
        epoch += 1; continuation.removeAll(); metadata.removeAll(); knownDuration = nil; lastRemotePosition = nil
        queuedQueries.removeAll()
        // Keep wire transactions alive to consume their acknowledgements, but
        // only subscription listeners carry over to the new content generation.
        pending = pending.mapValues {
            $0.pdu == 0x31 ? Pending(pdu: $0.pdu, event: $0.event, epoch: epoch, expires: $0.expires) : $0
        }
        currentTrack = nil; lastMetadata = .distantPast
        artwork = nil; fallbackArtwork = nil; coverMissingHandle = false; requestedHandle = nil
        if artworkState == .loaded { artworkState = .ready }
    }
    private func endTrackTransition() {
        transitionDeadline = nil
        if isChangingTrack { isChangingTrack = false }
    }
    private func finishTrackTransitionIfReady() {
        if currentTrack != nil, lastRemotePosition != nil, playbackState != .stopped {
            endTrackTransition()
        }
    }
    private func trace(_ message: String) {
        PhoneDiagnostics.write(message)
#if LYRICSX_PHONE_DIAGNOSTICS
        NSLog("LyricsX Phone: %@", message)
#endif
    }
    private func rebuildTrack() {
        guard let title = metadata[1], !title.isEmpty else { currentTrack = nil; return }
        let rawDuration = metadata[7].flatMap(Double.init).map { $0 / 1000 }
        let duration = knownDuration ?? rawDuration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let track = MusicTrack(id: trackID(for: metadata), title: title, album: metadata[3], artist: metadata[2], duration: duration, artwork: artwork ?? fallbackArtwork)
        if currentTrack?.id != track.id || currentTrack?.duration != track.duration || currentTrack?.artwork !== track.artwork {
            trace("publish track epoch=\(epoch)")
            currentTrack = track
        }
        finishTrackTransitionIfReady()
    }
    private func trackID(for values: [UInt32: String]) -> String {
        "phone:" + [savedAddress ?? "", values[1] ?? "", values[2] ?? "", values[3] ?? ""].joined(separator: "\u{1f}")
    }
    private func apply(_ status: AVRCPCodec.Status) {
        if previousMayRestart, let position = status.position, position <= 2, status.state == 1 {
            // Previous commonly restarts the current song without a track-change
            // notification. Its confirmed reset clock makes the same title valid.
            previousMayRestart = false
            skippedTrackID = nil; skipDeadline = nil
        }
        if currentTrack != nil, lastRemotePosition == nil,
           let duration = status.duration, let declared = metadata[7].flatMap(Double.init),
           declared > 0, duration > 0, abs(duration - declared / 1000) > 0.1 {
            trace("ignore status duration from previous element")
            lastStatusPoll = .distantPast
            return
        }
        if currentTrack != nil, let previousDuration = knownDuration,
           let duration = status.duration, duration > 0, duration != previousDuration {
            // New duration is already a strong change signal. Clear stale content
            // before waiting for the metadata reply to identify the next song.
            invalidateTrack(); requestMetadata()
        } else if let previous = lastRemotePosition, let position = status.position, position < previous - 2 {
            lastMetadata = .distantPast; requestMetadata()
        }
        lastRemotePosition = status.position
        remoteState = status.state
        if status.state == 0 || status.state == 2 || status.state == 255 { endTrackTransition() }
        if let duration = status.duration, duration > 0 { knownDuration = duration }
        rebuildTrack()
        guard let position = status.position, status.state != 255 else {
            playbackState = .stopped
            statusMessage = NSLocalizedString("Connected, but playback position is unavailable.", comment: "Phone source"); return
        }
        let time = min(knownDuration ?? position, position)
        let state: PlaybackState
        switch status.state {
        case 1: state = .playing(time: time)
        case 2: state = .paused(time: time)
        case 3: state = .fastForwarding(time: time)
        case 4: state = .rewinding(time: time)
        default: state = .stopped
        }
        if !playbackState.approximateEqual(to: state, tolerate: 0.3) { playbackState = state }
        finishTrackTransitionIfReady()
        statusMessage = NSLocalizedString("Phone connected.", comment: "Phone source")
    }
    func resume() { command(0x44) }
    func pause() { command(0x46) }
    func playPause() { command(remoteState == 1 ? 0x46 : 0x44) }
    func skipToNextItem() { command(0x4b) }
    func skipToPreviousItem() { command(0x4c) }
    private func command(_ operation: UInt8) {
        onMain { player in
            guard player.isConnected, player.commands.count < 32 else { return }
            if operation == 0x4b || operation == 0x4c {
                player.skippedTrackID = player.currentTrack?.id ?? player.skippedTrackID
                player.skipDeadline = player.now().addingTimeInterval(2)
                player.previousMayRestart = operation == 0x4c
                player.skipConfirmation = (player.currentTrack?.id ?? player.skipConfirmation?.origin,
                                           player.now().addingTimeInterval(2))
                player.invalidateTrack(renewSelectionGrace: true)
            }
            player.commands.append(operation)
            player.trace("enqueue command operation=\(operation) count=\(player.commands.count) epoch=\(player.epoch)")
            player.drainCommands()
            if operation == 0x4b || operation == 0x4c { player.lastMetadata = .distantPast; player.requestMetadata() }
            player.request(pdu: 0x30)
        }
    }
    private func drainCommands() {
        guard isConnected, !sendingCommand, !commands.isEmpty,
              !pending.values.contains(where: { $0.pdu == 0x7c }), pending.count <= 14 else { return }
        sendingCommand = true
        let operation = commands.removeFirst()
        // Reserve both labels before sending, including for synchronous test transports.
        guard let pressed = nextLabel() else { sendingCommand = false; commands.insert(operation, at: 0); return }
        pending[pressed] = Pending(pdu: 0x7c, event: operation, epoch: epoch, expires: now().addingTimeInterval(2))
        guard let released = nextLabel() else {
            pending[pressed] = nil; sendingCommand = false; commands.insert(operation, at: 0); return
        }
        pending[released] = Pending(pdu: 0x7c, event: operation | 0x80, epoch: epoch, expires: now().addingTimeInterval(2))
        transport.send(AVRCPCodec.passThrough(label: pressed, operation: operation, released: false))
        transport.send(AVRCPCodec.passThrough(label: released, operation: operation, released: true))
        sendingCommand = false
        if !pending.values.contains(where: { $0.pdu == 0x7c }) { drainCommands() }
    }
    private func onMain(_ action: @escaping (PhonePlayer) -> Void) {
        if Thread.isMainThread { action(self) }
        else { DispatchQueue.main.async { [weak self] in if let self = self { action(self) } } }
    }
}
