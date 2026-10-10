import Foundation
import IOBluetooth

protocol PhoneTransport: AnyObject {
    var onOpen: (() -> Void)? { get set }
    var onData: ((Data) -> Void)? { get set }
    var onClose: ((String) -> Void)? { get set }
    var onStatus: ((String) -> Void)? { get set }
    func connect(address: String)
    func disconnect()
    func send(_ data: Data)
    var coverPSM: UInt16? { get }
}
extension PhoneTransport { var coverPSM: UInt16? { nil } }

final class NativePhoneBluetoothTransport: NSObject, PhoneTransport, IOBluetoothL2CAPChannelDelegate {
    var onOpen: (() -> Void)?
    var onData: ((Data) -> Void)?
    var onClose: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    override init() {
        precondition(CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--lyricsx-phone-worker" && CommandLine.arguments[2] == "media", "Native media connections must run in the media worker")
        super.init()
    }
    private(set) var coverPSM: UInt16?
    private var device: IOBluetoothDevice?
    private var channel: IOBluetoothL2CAPChannel?
    private var deadline: Timer?
    private var servicePoll: Timer?
    private var retiredConnections: [(Date, SDPQuery)] = []
    private var writeBuffers: [Int: (IOBluetoothL2CAPChannel, NSMutableData)] = [:]
    private var controllerRecord: IOBluetoothSDPServiceRecord?
    private var incomingNotification: IOBluetoothUserNotification?
    private var query: SDPQuery?
    private var generation = 0
    private enum Stage { case idle, baseband, services, media, open }
    private var stage: Stage = .idle

    private final class SDPQuery: NSObject {
        let connected: (IOBluetoothDevice?, IOReturn) -> Void
        let complete: (IOBluetoothDevice?, IOReturn) -> Void
        init(connected: @escaping (IOBluetoothDevice?, IOReturn) -> Void, complete: @escaping (IOBluetoothDevice?, IOReturn) -> Void) {
            self.connected = connected; self.complete = complete
        }
        @objc func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) { connected(device, status) }
        @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) { complete(device, status) }
    }

    // AVRCP 1.6 Controller; optional cover traffic runs in a separate worker.
    // no audio or media-library browsing profile.
    static var controllerService: [String: Any] {
        func uint16(_ value: UInt16) -> [String: Any] {
            ["DataElementType": 1, "DataElementSize": 2, "DataElementValue": Data([UInt8(value >> 8), UInt8(value & 255)])]
        }
        func uuid(_ value: UInt16) -> Data { Data([UInt8(value >> 8), UInt8(value & 255)]) }
        return [
            "0001": [uuid(0x110e), uuid(0x110f)],
            "0004": [[uuid(0x0100), uint16(0x17)], [uuid(0x0017), uint16(0x0104)]],
            "0005": [uuid(0x1002)],
            "0009": [[uuid(0x110e), uint16(0x0106)]],
            "0100": "LyricsX Phone Controller",
            "0311": uint16(0x0201),
            "LocalAttributes": ["Persistent": false],
        ]
    }
    private var writeSequence = 0

    static func ownsControllerRecord(_ record: IOBluetoothSDPServiceRecord) -> Bool {
        record.getServiceName() == "LyricsX Phone Controller"
            && record.getAttributeDataElement(0x0311)?.getNumberValue()?.uint16Value == 0x0201
    }

    func connect(address: String) {
        disconnect()
        guard let device = IOBluetoothDevice(addressString: address), device.isPaired() else {
            onClose?(NSLocalizedString("Pair your phone in Bluetooth settings first.", comment: "Phone source")); return
        }
        self.device = device
        stage = .baseband
        guard let record = IOBluetoothSDPServiceRecord.publishedServiceRecord(with: Self.controllerService) else {
            fail(NSLocalizedString("The Mac could not register the Bluetooth media controller.", comment: "Phone source")); return
        }
        // macOS can return its built-in AVRCP record instead of the supplied
        // attributes (observed: no service name, version 1.5, features 0x0002).
        // Never remove or claim incoming channels for a system-owned record.
        let ownsRecord = Self.ownsControllerRecord(record)
        PhoneDiagnostics.write("local controller owned=" + String(ownsRecord)
            + " features=" + String(record.getAttributeDataElement(0x0311)?.getNumberValue()?.uint16Value ?? 0))
        if ownsRecord {
            controllerRecord = record
            var psm: BluetoothL2CAPPSM = 0
            guard record.getL2CAPPSM(&psm) == kIOReturnSuccess else { fail(error(kIOReturnError)); return }
            if psm == 0x17 {
                incomingNotification = IOBluetoothL2CAPChannel.register(forChannelOpenNotifications: self, selector: #selector(incoming(_:channel:)), withPSM: 0x17, direction: kIOBluetoothUserNotificationChannelDirectionIncoming)
            } else {
                _ = record.remove(); controllerRecord = nil
            }
        }
        let attempt = generation
        retiredConnections.removeAll { $0.0 < Date() }
        let query = SDPQuery(connected: { [weak self] device, status in
            guard let self = self, self.generation == attempt, let device = device else { return }
            guard status == kIOReturnSuccess || device.isConnected() else { self.fail(self.error(status)); return }
            self.queryServices(device)
        }, complete: { [weak self] device, status in
            guard let self = self, self.generation == attempt, let device = device else { return }
            self.sdpQueryComplete(device, status: status)
        })
        self.query = query
        if device.isConnected() { queryServices(device) }
        else {
            onStatus?(NSLocalizedString("Establishing the phone’s Bluetooth connection…", comment: "Phone source"))
            armDeadline(seconds: 20, message: "The phone did not accept the Bluetooth connection.")
            let result = device.openConnection(query)
            if result != kIOReturnSuccess {
                if device.isConnected() { queryServices(device) }
                else { fail(error(result)) }
            }
        }
    }
    private func queryServices(_ device: IOBluetoothDevice) {
        guard device === self.device, stage == .baseband else { return }
        stage = .services
        deadline?.invalidate(); deadline = nil
        onStatus?(NSLocalizedString("Checking the phone’s Bluetooth services…", comment: "Phone source"))
        // macOS 27's targeted SDP API is a no-op and its update timestamp is
        // Date(). The AVRCP control PSM is standardized; peer responses establish
        // media capability. Cover discovery uses an actual SDP channel separately.
        LXPrepareBluetoothCallbacks(device)
        openMediaChannel(device)
    }
    private func armDeadline(seconds: TimeInterval, message: String) {
        deadline?.invalidate()
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            self?.fail(NSLocalizedString(message, comment: "Phone source"))
        }
        deadline = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func disconnect() {
        generation += 1
        stage = .idle
        coverPSM = nil
        deadline?.invalidate(); deadline = nil
        servicePoll?.invalidate(); servicePoll = nil
        // Connection callbacks use an unretained target too. Keep timed-out targets
        // beyond the native paging timeout, with attempt IDs rejecting late events.
        if let query = query { retiredConnections.append((Date().addingTimeInterval(60), query)) }
        query = nil
        retiredConnections.removeAll { $0.0 < Date() }
        incomingNotification?.unregister(); incomingNotification = nil
        _ = controllerRecord?.remove(); controllerRecord = nil
        let previous = channel
        channel = nil; device = nil
        _ = previous?.close()
        // Keep the delegate until close/write completion releases in-flight buffers.
        // Do not close the device's baseband connection: other profiles may be using it.
    }
    private func sdpQueryComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        guard device === self.device, status == kIOReturnSuccess else { return }
        servicePoll?.invalidate(); servicePoll = nil
        openMediaChannel(device)
    }
    private func openMediaChannel(_ device: IOBluetoothDevice) {
        guard device === self.device, stage == .services, channel == nil else { return }
        stage = .media
        coverPSM = nil // No cached endpoint is advertised as fresh discovery.
        onStatus?(NSLocalizedString("Connecting to the phone’s media controller…", comment: "Phone source"))
        armDeadline(seconds: 12, message: "The phone did not accept the media connection.")
        let result = device.openL2CAPChannelAsync(&channel, withPSM: 0x17, delegate: self)
        if result != kIOReturnSuccess { fail(error(result)) }
    }
    @objc private func incoming(_ notification: IOBluetoothUserNotification, channel: IOBluetoothL2CAPChannel) {
        // Never take over another device's channel or an existing system-owned connection.
        guard channel.device === device, self.channel == nil else { return }
        self.channel = channel
        _ = channel.setDelegate(self)
    }
    func l2capChannelOpenComplete(_ channel: IOBluetoothL2CAPChannel!, status error: IOReturn) {
        guard channel === self.channel else { return }
        guard error == kIOReturnSuccess else { fail(self.error(error)); return }
        stage = .open
        deadline?.invalidate(); deadline = nil
        servicePoll?.invalidate(); servicePoll = nil
        onOpen?()
    }
    func l2capChannelData(_ channel: IOBluetoothL2CAPChannel!, data pointer: UnsafeMutableRawPointer!, length: Int) {
        guard channel === self.channel, let pointer = pointer, length >= 0, length <= 65536 else { return }
        let data = Data(bytes: pointer, count: length)
        PhoneDiagnostics.write("wire receive bytes=\(length) label=\((data.first ?? 0) >> 4)")
        onData?(data)
    }
    func l2capChannelClosed(_ channel: IOBluetoothL2CAPChannel!) {
        writeBuffers = writeBuffers.filter { $0.value.0 !== channel }
        _ = channel.setDelegate(nil)
        guard channel === self.channel else { return }
        fail(NSLocalizedString("Phone disconnected.", comment: "Phone source"))
    }
    func send(_ data: Data) {
        guard let channel = channel else { return }
        guard writeBuffers.count < 64, data.count <= Int(channel.outgoingMTU), data.count <= Int(UInt16.max) else { fail(error(kIOReturnNoResources)); return }
        writeSequence += 1
        let token = writeSequence
        let buffer = NSMutableData(data: data)
        writeBuffers[token] = (channel, buffer)
        PhoneDiagnostics.write("wire send bytes=\(data.count) label=\((data.first ?? 0) >> 4)")
        let result = channel.writeAsync(buffer.mutableBytes, length: UInt16(buffer.length), refcon: UnsafeMutableRawPointer(bitPattern: token))
        if result != kIOReturnSuccess { writeBuffers[token] = nil; fail(error(result)) }
    }
    func l2capChannelWriteComplete(_ channel: IOBluetoothL2CAPChannel!, refcon: UnsafeMutableRawPointer!, status error: IOReturn) {
        writeBuffers[Int(bitPattern: refcon)] = nil
        if channel === self.channel, error != kIOReturnSuccess { fail(self.error(error)) }
    }
    private func fail(_ message: String) { disconnect(); onClose?(message) }
    private func error(_ result: IOReturn) -> String {
        String(format: NSLocalizedString("Bluetooth connection failed (%@).", comment: "Phone source"), String(format: "%08X", result))
    }
}
