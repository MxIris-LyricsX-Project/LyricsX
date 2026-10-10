import Foundation
import IOBluetooth

/// Runs only in --lyricsx-phone-worker processes, before NSApplicationMain.
/// Native Bluetooth callbacks may block this process's main run loop; the parent
/// can end it without touching the application UI or the other Bluetooth worker.
final class PhoneWorkerRuntime {
    private let role: PhoneWorkerRole
    private var media: NativePhoneBluetoothTransport?
    private var cover: NativePhoneCoverArt?
    private let inputQueue = DispatchQueue(label: "PhoneWorkerInput")
    private let outputQueue = DispatchQueue(label: "PhoneWorkerOutput")
    private var frames = PhoneWorkerFrames(limit: 128 * 1024)

    private init(role: PhoneWorkerRole) { self.role = role }

    static func run(role: PhoneWorkerRole) -> Never {
        let worker = PhoneWorkerRuntime(role: role)
        let input = FileHandle.standardInput
        input.readabilityHandler = { [weak worker] handle in
            let data = handle.availableData
            // EOF must end an orphan even if its native main thread is blocked.
            guard !data.isEmpty else { exit(0) }
            worker?.inputQueue.async { [weak worker] in
                guard let worker = worker else { return }
                do {
                    for message in try worker.frames.append(data) {
                        DispatchQueue.main.async { worker.handle(message) }
                    }
                } catch { exit(1) }
            }
        }
        let heartbeat = Timer(timeInterval: 0.5, repeats: true) { _ in worker.emit(PhoneWorkerMessage(kind: .heartbeat)) }
        RunLoop.main.add(heartbeat, forMode: .common)
        if role == .inventory { worker.listDevices() }
        withExtendedLifetime(worker) { RunLoop.main.run() }
        exit(0)
    }

    private func emit(_ message: PhoneWorkerMessage) {
        guard let bytes = message.encoded() else { exit(1) }
        outputQueue.async { FileHandle.standardOutput.write(bytes) }
    }
    private func validAddress(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 17 else { return false }
        for (index, byte) in bytes.enumerated() {
            if index % 3 == 2 { if byte != 45 && byte != 58 { return false } }
            else if !(48...57).contains(byte) && !(65...70).contains(byte) && !(97...102).contains(byte) { return false }
        }
        return true
    }
    private func handle(_ message: PhoneWorkerMessage) {
        switch message.kind {
        case .connect:
            guard let address = message.address, validAddress(address) else { exit(1) }
            if role == .media, media == nil {
                let transport = NativePhoneBluetoothTransport()
                media = transport
                transport.onOpen = { [weak self, weak transport] in self?.emit(PhoneWorkerMessage(kind: .open, psm: transport?.coverPSM)) }
                transport.onData = { [weak self] data in self?.emit(PhoneWorkerMessage(kind: .data, bytes: data)) }
                transport.onStatus = { [weak self] text in self?.emit(PhoneWorkerMessage(kind: .status, text: text)) }
                transport.onClose = { [weak self] text in self?.emit(PhoneWorkerMessage(kind: .closed, text: text)) }
                transport.connect(address: address)
            } else if role == .cover, cover == nil {
                let transport = NativePhoneCoverArt(enabled: true)
                cover = transport
                transport.onReady = { [weak self] in self?.emit(PhoneWorkerMessage(kind: .ready)) }
                transport.onImage = { [weak self] handle, bytes in self?.emit(PhoneWorkerMessage(kind: .image, bytes: bytes, handle: handle)) }
                transport.onState = { [weak self] state in self?.emit(PhoneWorkerMessage(kind: .artworkState, artworkState: state)) }
                guard message.psm.map(NativePhoneCoverArt.validPSM) ?? true else { exit(1) }
                transport.connect(address: address, psm: message.psm)
            } else { exit(1) }
        case .send:
            guard role == .media, let bytes = message.bytes, !bytes.isEmpty, bytes.count <= 65536 else { exit(1) }
            media?.send(bytes)
        case .fetch:
            guard role == .cover, let handle = message.handle, handle.utf8.count == 7,
                  handle.utf8.allSatisfy({ (48...57).contains($0) }) else { exit(1) }
            cover?.fetch(handle: handle)
        case .restartSession:
            guard role == .cover else { exit(1) }
            cover?.restartSession()
        default: exit(1)
        }
    }
    private func listDevices() {
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        var seen = Set<String>()
        let devices = paired.compactMap { device -> PhonePairedDevice? in
            guard let address = device.addressString, seen.insert(address).inserted else { return nil }
            return PhonePairedDevice(address: address,
                                     name: device.name ?? NSLocalizedString("Unknown Device", comment: "Phone source"),
                                     isMobile: PhonePairedDevice.isMobileClass(major: UInt32(device.deviceClassMajor),
                                                                             minor: UInt32(device.deviceClassMinor)))
        }.sorted {
            if $0.isMobile != $1.isMobile { return $0.isMobile }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        emit(PhoneWorkerMessage(kind: .devices, devices: devices))
    }
}
