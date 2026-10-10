import Foundation
import IOBluetooth

/// UI-side proxy. It never constructs native Bluetooth devices or channels.
final class PhoneBluetoothTransport: PhoneTransport {
    var onOpen: (() -> Void)?
    var onData: ((Data) -> Void)?
    var onClose: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    private(set) var coverPSM: UInt16?
    private let worker: PhoneWorkerProcess
    static var controllerService: [String: Any] { NativePhoneBluetoothTransport.controllerService }

    init(worker: PhoneWorkerProcess = PhoneWorkerProcess()) {
        self.worker = worker
        worker.onMessage = { [weak self] message in
            guard let self = self else { return }
            switch message.kind {
            case .open:
                self.coverPSM = message.psm.flatMap { NativePhoneCoverArt.validPSM($0) ? $0 : nil }
                self.onOpen?()
            case .data:
                if let data = message.bytes, data.count <= 65536 { self.onData?(data) }
            case .status:
                if let text = message.text { self.onStatus?(text) }
            case .closed:
                self.worker.stop()
                self.onClose?(message.text ?? Self.failureMessage)
            default: break
            }
        }
        worker.onFailure = { [weak self] in self?.onClose?(Self.failureMessage) }
    }
    deinit { worker.stop() }
    private static var failureMessage: String {
        NSLocalizedString("The phone is not sharing playback information.", comment: "Phone source")
    }
    func connect(address: String) { coverPSM = nil; worker.start(role: .media, address: address) }
    func disconnect() { worker.stop() }
    func send(_ data: Data) { worker.send(PhoneWorkerMessage(kind: .send, bytes: data)) }
}

/// Cover traffic has its own process, independent of the media worker. A stalled
/// image connection is ended by the supervisor. The UI may then request a web fallback.
final class PhoneCoverArt: PhoneArtworkTransport {
    var onReady: (() -> Void)?
    var onImage: ((String, Data) -> Void)?
    var onState: ((PhoneArtworkState) -> Void)?
    private let worker: PhoneWorkerProcess
    private var attemptedEndpoints = Set<String>()
    static func psm(in record: IOBluetoothSDPServiceRecord) -> UInt16? { NativePhoneCoverArt.psm(in: record) }

    init(worker: PhoneWorkerProcess = PhoneWorkerProcess()) {
        self.worker = worker
        worker.onMessage = { [weak self] message in
            guard let self = self else { return }
            switch message.kind {
            case .ready: self.onReady?()
            case .image:
                if let handle = message.handle, let bytes = message.bytes { self.onImage?(handle, bytes) }
            case .artworkState:
                if let state = message.artworkState {
                    self.onState?(state)
                    if state == .unavailable { self.worker.stop() }
                }
            default: break
            }
        }
        worker.onFailure = { [weak self] in self?.onState?(.unavailable) }
    }
    deinit { worker.stop() }
    func connect(address: String) { connect(address: address, psm: nil) }
    func connect(address: String, psm: UInt16?) {
        disconnect()
        // Capability can appear later. Retry a newly advertised endpoint, while
        // never repeatedly opening the same failed image channel.
        let endpoint = address + "/" + String(psm ?? 0)
        guard attemptedEndpoints.insert(endpoint).inserted else { return }
        onState?(.connecting)
        worker.start(role: .cover, address: address, psm: psm)
    }
    func fetch(handle: String) { worker.send(PhoneWorkerMessage(kind: .fetch, handle: handle)) }
    func restartSession() { worker.send(PhoneWorkerMessage(kind: .restartSession)) }
    func disconnect() { worker.stop(); onState?(.unavailable) }
}

/// Device enumeration is also isolated: a busy Bluetooth daemon cannot freeze the
/// preferences window when it opens or the user presses Refresh Devices.
final class PhoneDeviceInventory {
    private let worker = PhoneWorkerProcess()
    func refresh(_ completion: @escaping ([PhonePairedDevice]) -> Void) {
        worker.onMessage = { [weak self] message in
            guard message.kind == .devices, let devices = message.devices else { return }
            self?.worker.stop(); completion(devices)
        }
        worker.onFailure = { completion([]) }
        worker.start(role: .inventory)
    }
    func cancel() { worker.stop() }
    deinit { worker.stop() }
}
