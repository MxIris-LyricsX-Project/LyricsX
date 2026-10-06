import Foundation
import StatusItemProbeSupport

/// Wraps the `StatusItemProbeHost` executable in a throwaway, ad-hoc signed
/// `.app` and runs one request through it.
///
/// The bundle is what makes the probe real: with a bundle identifier the
/// system menu bar hosts the item from replicant snapshots, as it does for
/// LyricsX; without one the item stays on the in-process window and no
/// snapshot is ever taken. The bundle is rebuilt in the same place on every
/// run so Launch Services keeps seeing one probe app rather than one per run.
enum StatusItemProbeHostLauncher {
    static let bundleIdentifier = "dev.JH.LyricsX.StatusItemProbe"
    private static let executableName = "StatusItemProbeHost"

    /// One live launch at a time across every suite: they share the bundle,
    /// and two apps measuring at once would skew each other's CPU readings.
    private static let launchLock = LaunchLock()

    static func run<Report: Decodable>(
        as reportType: Report.Type = StatusItemProbeReport.self,
        timeoutSeconds: Double = 30,
        _ makeRequest: (_ reportPath: String) -> StatusItemProbeRequest
    ) async throws -> Report {
        await launchLock.acquire()
        do {
            let report = try await runExclusively(as: reportType, timeoutSeconds: timeoutSeconds, makeRequest)
            await launchLock.release()
            return report
        } catch {
            await launchLock.release()
            throw error
        }
    }

    private static func runExclusively<Report: Decodable>(
        as reportType: Report.Type,
        timeoutSeconds: Double,
        _ makeRequest: (_ reportPath: String) -> StatusItemProbeRequest
    ) async throws -> Report {
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LyricsXStatusItemProbe", isDirectory: true)
        let appBundle = try makeAppBundle(in: workDirectory)
        let reportURL = workDirectory.appendingPathComponent("report-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: reportURL) }
        let request = makeRequest(reportURL.path)

        // Launched through Launch Services, like a user-started app. Spawned
        // directly as a child of the test process, the host keeps its status
        // item on the in-process window even with a bundle identifier.
        let standardErrorURL = workDirectory.appendingPathComponent("stderr-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: standardErrorURL) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", "-W", "--stderr", standardErrorURL.path, appBundle.path, "--args"] + request.arguments
        try process.run()

        let deadline = Date().addingTimeInterval(request.settleSeconds + request.measuredSeconds + timeoutSeconds)
        while process.isRunning, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if process.isRunning {
            process.terminate()
            let killer = Process()
            killer.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            killer.arguments = ["-f", "LyricsXStatusItemProbe.app/Contents/MacOS/\(executableName)"]
            try? killer.run()
            killer.waitUntilExit()
            throw StatusItemProbeHostLauncherError.timedOut
        }
        guard let reportData = try? Data(contentsOf: reportURL) else {
            let message = (try? String(contentsOf: standardErrorURL, encoding: .utf8)) ?? ""
            throw StatusItemProbeHostLauncherError.hostFailed(status: process.terminationStatus, message: message)
        }
        return try JSONDecoder().decode(reportType, from: reportData)
    }

    private static func makeAppBundle(in workDirectory: URL) throws -> URL {
        let fileManager = FileManager.default
        let builtExecutable = productsDirectory.appendingPathComponent(executableName)
        guard fileManager.isExecutableFile(atPath: builtExecutable.path) else {
            throw StatusItemProbeHostLauncherError.missingHostExecutable(builtExecutable.path)
        }
        let appBundle = workDirectory.appendingPathComponent("LyricsXStatusItemProbe.app", isDirectory: true)
        try? fileManager.removeItem(at: appBundle)
        let executableDirectory = appBundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try fileManager.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
        try fileManager.copyItem(at: builtExecutable, to: executableDirectory.appendingPathComponent(executableName))

        let informationPropertyList: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleExecutable": executableName,
            "CFBundleName": "LyricsX Status Item Probe",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "12.0",
            "LSUIElement": true,
            "NSPrincipalClass": "NSApplication",
        ]
        try PropertyListSerialization
            .data(fromPropertyList: informationPropertyList, format: .xml, options: 0)
            .write(to: appBundle.appendingPathComponent("Contents/Info.plist"))

        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--force", "--sign", "-", appBundle.path]
        codesign.standardOutput = FileHandle.nullDevice
        codesign.standardError = FileHandle.nullDevice
        try codesign.run()
        codesign.waitUntilExit()
        guard codesign.terminationStatus == 0 else {
            throw StatusItemProbeHostLauncherError.signingFailed(codesign.terminationStatus)
        }
        return appBundle
    }

    /// Where SwiftPM put this test bundle — and the host executable beside it.
    private static var productsDirectory: URL {
        Bundle(for: ProductsDirectoryLocator.self).bundleURL.deletingLastPathComponent()
    }
}

private final class ProductsDirectoryLocator {}

/// A first-come, first-served lock for async callers.
private actor LaunchLock {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

enum StatusItemProbeHostLauncherError: Error {
    case missingHostExecutable(String)
    case signingFailed(Int32)
    case timedOut
    case hostFailed(status: Int32, message: String)
}
