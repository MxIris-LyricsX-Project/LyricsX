import Foundation
import Darwin

enum PhoneWorkerRole: String { case media, cover, inventory }

struct PhonePairedDevice: Codable {
    let address: String
    let name: String
    let isMobile: Bool

    /// Classic Bluetooth Class of Device, with the major/minor fields already shifted.
    /// Unclassified devices remain available in the other paired devices submenu.
    static func isMobileClass(major: UInt32, minor: UInt32) -> Bool {
        switch major {
        case 2: return [0, 1, 3].contains(minor) // Unspecified phone, cellular, smartphone.
        case 1: return [4, 5, 7].contains(minor) // Handheld, palm-size PDA, tablet.
        default: return false
        }
    }
}

struct PhoneWorkerMessage: Codable {
    enum Kind: String, Codable {
        case connect, send, fetch, restartSession, open, data, status, closed
        case ready, image, artworkState, devices, heartbeat
    }
    let kind: Kind
    var address: String? = nil
    var psm: UInt16? = nil
    var bytes: Data? = nil
    var handle: String? = nil
    var text: String? = nil
    var artworkState: PhoneArtworkState? = nil
    var devices: [PhonePairedDevice]? = nil

    func encoded() -> Data? {
        guard var data = try? JSONEncoder().encode(self) else { return nil }
        data.append(10)
        return data
    }
}

/// Newline framing with a bound, including incomplete frames. JSON escapes newlines
/// in string fields; Data uses base64. Nothing in this IPC is persisted to disk.
struct PhoneWorkerFrames {
    let limit: Int
    private var buffer = Data()
    private var scanned = 0
    init(limit: Int) { self.limit = limit }

    mutating func append(_ data: Data) throws -> [PhoneWorkerMessage] {
        buffer.append(data)
        var result: [PhoneWorkerMessage] = []
        while true {
            let start = buffer.index(buffer.startIndex, offsetBy: scanned)
            guard let end = buffer[start...].firstIndex(of: 10) else { scanned = buffer.count; break }
            let length = buffer.distance(from: buffer.startIndex, to: end)
            guard length > 0, length <= limit else { throw CocoaError(.coderReadCorrupt) }
            result.append(try JSONDecoder().decode(PhoneWorkerMessage.self, from: buffer.prefix(length)))
            buffer.removeFirst(length + 1); scanned = 0
        }
        guard buffer.count <= limit else { throw CocoaError(.coderReadCorrupt) }
        return result
    }
}

/// Supervises a child process. Launch, pipe reads/writes and process cleanup all
/// run off the UI thread; no waitUntilExit, semaphore wait, or Bluetooth API here.
final class PhoneWorkerProcess {
    var onMessage: ((PhoneWorkerMessage) -> Void)?
    var onFailure: (() -> Void)?
    private let executable: URL?
    private let arguments: (PhoneWorkerRole) -> [String]
    private let heartbeatTimeout: TimeInterval
    private let operationTimeout: TimeInterval?
    private let queue = DispatchQueue(label: "PhoneWorkerSupervisor", qos: .userInitiated)
    private let generationLock = NSLock()
    private var generation = 0
    // Below this line, state belongs exclusively to queue.
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var watchdog: DispatchSourceTimer?
    private var writer: DispatchSourceWrite?
    private var frames = PhoneWorkerFrames(limit: 4 * 1024 * 1024)
    private var pending = Data()
    private var lastHeartbeat: TimeInterval = 0
    private var deadline: TimeInterval?
    private var failed = false
    private var awaitingInitialConnection = false

    init(executable: URL? = Bundle.main.executableURL,
         arguments: @escaping (PhoneWorkerRole) -> [String] = { ["--lyricsx-phone-worker", $0.rawValue] },
         heartbeatTimeout: TimeInterval = 3, operationTimeout: TimeInterval? = nil) {
        self.executable = executable; self.arguments = arguments
        self.heartbeatTimeout = heartbeatTimeout; self.operationTimeout = operationTimeout
    }

    deinit {
        let child = process, reader = output, sender = input
        let timer = watchdog, writeSource = writer, cleanupQueue = queue
        cleanupQueue.async {
            timer?.cancel(); writeSource?.cancel(); reader?.readabilityHandler = nil
            child?.terminationHandler = nil
            if let child = child, child.isRunning {
                child.terminate()
                cleanupQueue.asyncAfter(deadline: .now() + 0.5) {
                    if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
                }
            }
            sender?.closeFile(); reader?.closeFile()
        }
    }

    private func nextGeneration() -> Int {
        generationLock.lock(); defer { generationLock.unlock() }
        generation += 1; return generation
    }
    private func isCurrent(_ value: Int) -> Bool {
        generationLock.lock(); defer { generationLock.unlock() }
        return value == generation
    }
    func start(role: PhoneWorkerRole, address: String? = nil, psm: UInt16? = nil) {
        let attempt = nextGeneration()
        queue.async { [weak self] in
            guard let self = self, self.isCurrent(attempt) else { return }
            self.cleanup()
            self.failed = false
            guard let executable = self.executable else { self.fail(attempt); return }
            let child = Process(), incoming = Pipe(), outgoing = Pipe()
            child.executableURL = executable; child.arguments = self.arguments(role)
            child.standardInput = incoming; child.standardOutput = outgoing
            // Framework diagnostics must never enter the IPC stream or fill a pipe.
            child.standardError = FileHandle.nullDevice
            child.terminationHandler = { [weak self] _ in
                self?.queue.async { [weak self] in
                    guard let self = self, self.isCurrent(attempt), self.process === child else { return }
                    self.fail(attempt)
                }
            }
            self.process = child; self.input = incoming.fileHandleForWriting
            self.output = outgoing.fileHandleForReading
            outgoing.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                self?.queue.async { [weak self] in
                    guard let self = self, self.isCurrent(attempt), self.process === child else { return }
                    guard !data.isEmpty else { self.fail(attempt); return }
                    do {
                        for message in try self.frames.append(data) { self.receive(message, role: role, attempt: attempt) }
                    } catch { self.fail(attempt) }
                }
            }
            do { try child.run() } catch { self.fail(attempt); return }
            incoming.fileHandleForReading.closeFile(); outgoing.fileHandleForWriting.closeFile()
            let fd = incoming.fileHandleForWriting.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            _ = fcntl(fd, F_SETNOSIGPIPE, 1)
            self.awaitingInitialConnection = role == .media && address != nil
            self.lastHeartbeat = ProcessInfo.processInfo.systemUptime
            self.deadline = self.lastHeartbeat + (self.operationTimeout ?? (role == .media ? 26 : role == .cover ? 12 : 8))
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
            timer.setEventHandler { [weak self] in
                guard let self = self, self.isCurrent(attempt) else { return }
                let now = ProcessInfo.processInfo.systemUptime
                // IOBluetooth's initial baseband call can synchronously wait
                // for paging in this child. Give it the explicit connection
                // deadline, not the shorter steady-state heartbeat deadline.
                // The UI never waits, and process exit still fails immediately.
                let missedHeartbeat = now - self.lastHeartbeat > self.heartbeatTimeout
                    && !self.awaitingInitialConnection
                if missedHeartbeat || self.deadline.map({ now > $0 }) == true {
                    self.fail(attempt)
                }
            }
            self.watchdog = timer; timer.resume()
            if let address = address { self.enqueue(PhoneWorkerMessage(kind: .connect, address: address, psm: psm), attempt: attempt) }
        }
    }

    func send(_ message: PhoneWorkerMessage) {
        generationLock.lock(); let attempt = generation; generationLock.unlock()
        queue.async { [weak self] in
            guard let self = self, self.isCurrent(attempt), self.process != nil else { return }
            if message.kind == .fetch { self.deadline = ProcessInfo.processInfo.systemUptime + 8 }
            if message.kind == .restartSession { self.deadline = ProcessInfo.processInfo.systemUptime + (self.operationTimeout ?? 12) }
            self.enqueue(message, attempt: attempt)
        }
    }
    func stop() {
        _ = nextGeneration() // Immediately reject callbacks already enqueued for the UI.
        queue.async { [weak self] in self?.cleanup() }
    }
    private func enqueue(_ message: PhoneWorkerMessage, attempt: Int) {
        guard !failed, let bytes = message.encoded(), pending.count + bytes.count <= 128 * 1024 else { fail(attempt); return }
        pending.append(bytes); drain(attempt)
    }
    private func drain(_ attempt: Int) {
        guard !failed, let input = input else { return }
        let fd = input.fileDescriptor
        while !pending.isEmpty {
            let count = pending.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if count > 0 { pending.removeFirst(count); continue }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN {
                if writer == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
                    source.setEventHandler { [weak self] in
                        guard let self = self, self.isCurrent(attempt) else { return }
                        self.drain(attempt)
                    }
                    writer = source; source.resume()
                }
                return
            }
            fail(attempt); return
        }
        writer?.cancel(); writer = nil
    }
    private func receive(_ message: PhoneWorkerMessage, role: PhoneWorkerRole, attempt: Int) {
        guard !failed else { return }
        if message.kind == .heartbeat { lastHeartbeat = ProcessInfo.processInfo.systemUptime; return }
        let permitted: Set<PhoneWorkerMessage.Kind>
        switch role {
        case .media: permitted = [.open, .data, .status, .closed]
        case .cover: permitted = [.ready, .image, .artworkState]
        case .inventory: permitted = [.devices]
        }
        guard permitted.contains(message.kind), (message.bytes?.count ?? 0) <= 2 * 1024 * 1024 else { fail(attempt); return }
        if message.kind == .open || message.kind == .ready || message.kind == .image {
            deadline = nil; awaitingInitialConnection = false
            lastHeartbeat = ProcessInfo.processInfo.systemUptime
        }
        if message.kind == .data { PhoneDiagnostics.write("ipc receive label=\((message.bytes?.first ?? 0) >> 4)") }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isCurrent(attempt) else { return }
            self.onMessage?(message)
        }
    }
    private func fail(_ attempt: Int) {
        guard !failed, isCurrent(attempt) else { return }
        failed = true; cleanup()
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isCurrent(attempt) else { return }
            self.onFailure?()
        }
    }
    private func cleanup() {
        watchdog?.cancel(); watchdog = nil
        writer?.cancel(); writer = nil
        output?.readabilityHandler = nil
        let child = process; process = nil
        child?.terminationHandler = nil
        if let child = child, child.isRunning {
            child.terminate()
            // A blocked framework callback need not cooperate with termination.
            // Kill only this owned child; never wait for its exit on the UI thread.
            queue.asyncAfter(deadline: .now() + 0.5) {
                if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
            }
        }
        input?.closeFile(); input = nil
        output?.closeFile(); output = nil
        pending.removeAll(); frames = PhoneWorkerFrames(limit: 4 * 1024 * 1024); deadline = nil
        awaitingInitialConnection = false
    }
}
