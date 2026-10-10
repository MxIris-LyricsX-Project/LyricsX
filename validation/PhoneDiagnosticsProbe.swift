import Foundation

@main enum PhoneDiagnosticsProbe {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("lyricsx-phone-diagnostics-enabled")
        let log = directory.appendingPathComponent("lyricsx-phone-diagnostics-\(ProcessInfo.processInfo.processIdentifier).log")
        var time = Date()
        let store = PhoneDiagnosticsStore(directory: directory, limit: 100, lifetime: 60, now: { time })
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fatalError(message) }
            count += 1
        }
        store.write("disabled")
        check(!FileManager.default.fileExists(atPath: log.path), "disabled diagnostics create no file")
        try Data().write(to: marker)
        time = Date().addingTimeInterval(1)
        check(store.enabled, "fresh marker enables diagnostics")
        store.write("packet")
        let first = try Data(contentsOf: log)
        check(!first.isEmpty, "enabled diagnostics record a packet")
        for _ in 0..<30 { store.write("packet") }
        let bounded = try Data(contentsOf: log)
        check(bounded.count <= 100, "log cannot grow beyond cap")
        time = time.addingTimeInterval(61)
        check(!store.enabled, "old marker automatically expires")
        store.write("expired")
        let final = try Data(contentsOf: log)
        check(final == bounded, "expired diagnostics do not append")
        print("\(count) diagnostics checks passed")
    }
}
