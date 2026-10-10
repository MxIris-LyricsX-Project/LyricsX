import Foundation

/// Local opt-in diagnostics expire after 15 minutes and stop at 1 MiB per
/// process. Protocol callers omit device addresses and song metadata values.
enum PhoneDiagnostics {
    private static let store = PhoneDiagnosticsStore(directory: URL(fileURLWithPath: NSTemporaryDirectory()))
    static var enabled: Bool { store.enabled }
    static func write(_ message: String) { store.write(message) }
}

final class PhoneDiagnosticsStore {
    private let marker: URL
    private let log: URL
    private let limit: UInt64
    private let lifetime: TimeInterval
    private let now: () -> Date
    private let lock = NSLock()

    init(directory: URL, limit: UInt64 = 1024 * 1024, lifetime: TimeInterval = 15 * 60, now: @escaping () -> Date = Date.init) {
        marker = directory.appendingPathComponent("lyricsx-phone-diagnostics-enabled")
        log = directory.appendingPathComponent("lyricsx-phone-diagnostics-\(ProcessInfo.processInfo.processIdentifier).log")
        self.limit = limit
        self.lifetime = lifetime
        self.now = now
    }

    var enabled: Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: marker.path),
              let date = attributes[.modificationDate] as? Date else { return false }
        let age = now().timeIntervalSince(date)
        return age >= 0 && age < lifetime
    }

    func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        guard enabled else { return }
        let data = Data((String(now().timeIntervalSince1970) + " " + message + "\n").utf8)
        guard data.count <= limit else { return }
        if !FileManager.default.fileExists(atPath: log.path) {
            guard FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return }
        }
        guard let file = try? FileHandle(forWritingTo: log) else { return }
        defer { try? file.close() }
        guard let size = try? file.seekToEnd(), size <= limit, UInt64(data.count) <= limit - size else { return }
        try? file.write(contentsOf: data)
    }
}
