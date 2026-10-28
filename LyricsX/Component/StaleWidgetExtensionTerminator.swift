import Darwin
import Foundation
import LyricsXWidgetShared
import WidgetKit

/// Ends the widget extension processes an earlier version of the app left
/// running, so the desktop widgets get the installed extension.
///
/// Sparkle installs an update after the app quits and never touches the widget
/// extension, whose process goes on answering the widgets from the old app's
/// deleted files until the user logs out. Sparkle's maintainers suggest the
/// app restart its extensions itself, on the first launch after an update;
/// this runs on every launch, which also covers an app copied over by hand.
/// Which processes count is `WidgetExtensionProcessPolicy`'s call; why it
/// matters is in `Documentations/Internal/DesktopWidget.md`.
@Loggable(subsystem: "com.JH.LyricsX.diagnostics", category: "StaleWidgetExtension")
final class StaleWidgetExtensionTerminator {
    private static let widgetExtensionPointIdentifier = "com.apple.widgetkit-extension"
    /// Regions to look through for the one a process's executable is mapped
    /// in. It comes right after the zero page, so the first few hold it.
    private static let regionSearchLimit = 64
    /// The length of `proc_bsdinfo.pbi_name`, the longer of the two names the
    /// kernel keeps for a process.
    private static let processNameLength = 2 * Int(MAXCOMLEN)

    /// Ends every stale widget extension process and, if there was one, asks
    /// the widgets to reload, which starts the installed extension.
    func terminateStaleProcesses() {
        guard let installed = installedWidgetExtension() else { return }
        let executableName = (installed.executablePath as NSString).lastPathComponent
        // The kernel keeps a process's name at most this long.
        let processName = String(executableName.prefix(Self.processNameLength))
        var terminatedCount = 0
        for processIdentifier in allProcessIdentifiers() where processIdentifier != getpid() {
            guard name(of: processIdentifier) == processName,
                  let executable = mappedExecutable(of: processIdentifier, named: executableName)
            else {
                continue
            }
            let executablePath = executable.path
            let process = WidgetExtensionProcessPolicy.RunningProcess(
                processIdentifier: processIdentifier,
                executablePath: executablePath,
                executableFile: executable.file,
                fileAtPath: fileAtPath(executablePath)
            )
            guard WidgetExtensionProcessPolicy.isStale(process, installed: installed) else { continue }
            if kill(processIdentifier, SIGTERM) == 0 {
                terminatedCount += 1
                #log(.info, "Ended stale widget extension \(processIdentifier, privacy: .public) at \(executablePath, privacy: .public)")
            } else {
                #log(.error, "Could not end stale widget extension \(processIdentifier, privacy: .public): errno \(errno, privacy: .public)")
            }
        }
        if terminatedCount > 0 {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    // MARK: - The installed extension

    private func installedWidgetExtension() -> WidgetExtensionProcessPolicy.InstalledExtension? {
        guard let plugInsURL = Bundle.main.builtInPlugInsURL,
              let plugInURLs = try? FileManager.default.contentsOfDirectory(at: plugInsURL, includingPropertiesForKeys: nil)
        else {
            return nil
        }
        for plugInURL in plugInURLs where plugInURL.pathExtension == "appex" {
            guard let information = Self.bundleInformation(at: plugInURL),
                  let extensionAttributes = information["NSExtension"] as? [String: Any],
                  extensionAttributes["NSExtensionPointIdentifier"] as? String == Self.widgetExtensionPointIdentifier,
                  let executableName = information["CFBundleExecutable"] as? String,
                  let bundleIdentifier = information["CFBundleIdentifier"] as? String,
                  let bundleVersion = information["CFBundleVersion"] as? String
            else {
                continue
            }
            let executablePath = plugInURL
                .appendingPathComponent("Contents/MacOS", isDirectory: true)
                .appendingPathComponent(executableName)
                .resolvingSymlinksInPath()
                .path
            guard let executableFile = Self.fileIdentity(atPath: executablePath) else { return nil }
            return WidgetExtensionProcessPolicy.InstalledExtension(
                executablePath: executablePath,
                executableFile: executableFile,
                bundleIdentifier: bundleIdentifier,
                bundleVersion: bundleVersion
            )
        }
        return nil
    }

    // MARK: - Other processes

    private func allProcessIdentifiers() -> [pid_t] {
        let estimatedCount = proc_listallpids(nil, 0)
        guard estimatedCount > 0 else { return [] }
        // Room for processes started between the two calls.
        var processIdentifiers = [pid_t](repeating: 0, count: Int(estimatedCount) + 64)
        let filledCount = processIdentifiers.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard filledCount > 0 else { return [] }
        return Array(processIdentifiers.prefix(Int(filledCount)))
    }

    /// The process's name as the kernel keeps it, from `proc_bsdinfo.pbi_name`.
    /// `proc_name` refuses a buffer shorter than that field, so this one has
    /// room for all of it and a terminating zero.
    private func name(of processIdentifier: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Self.processNameLength + 1)
        guard proc_name(processIdentifier, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Where `processIdentifier`'s executable is and which file it is, read
    /// from the memory region the executable is mapped in — what `lsof` lists
    /// as the process's text. Both hold for a file the update deleted: the
    /// path is the last one it had, and the file is still told apart from a
    /// new one written to the same place.
    private func mappedExecutable(
        of processIdentifier: pid_t,
        named executableName: String
    ) -> (path: String, file: WidgetExtensionProcessPolicy.FileIdentity)? {
        var regionInformation = proc_regionwithpathinfo()
        let informationSize = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
        var address: UInt64 = 0
        for _ in 0 ..< Self.regionSearchLimit {
            guard proc_pidinfo(processIdentifier, PROC_PIDREGIONPATHINFO, address, &regionInformation, informationSize) == informationSize else {
                return nil
            }
            let regionPath = withUnsafeBytes(of: regionInformation.prp_vip.vip_path) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            if (regionPath as NSString).lastPathComponent == executableName {
                let fileStatus = regionInformation.prp_vip.vip_vi.vi_stat
                let file = WidgetExtensionProcessPolicy.FileIdentity(device: UInt64(fileStatus.vst_dev), inode: fileStatus.vst_ino)
                return (regionPath, file)
            }
            let nextAddress = regionInformation.prp_prinfo.pri_address + regionInformation.prp_prinfo.pri_size
            guard nextAddress > address else { return nil }
            address = nextAddress
        }
        return nil
    }

    private func fileAtPath(_ executablePath: String) -> WidgetExtensionProcessPolicy.FileAtPath {
        guard FileManager.default.fileExists(atPath: executablePath) else { return .missing }
        // <name>.appex/Contents/MacOS/<executable>
        let bundleURL = URL(fileURLWithPath: executablePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let information = Self.bundleInformation(at: bundleURL)
        return .present(
            bundleIdentifier: information?["CFBundleIdentifier"] as? String,
            bundleVersion: information?["CFBundleVersion"] as? String
        )
    }

    // MARK: - Files

    /// Read from the file rather than through `Bundle`, which caches a
    /// bundle's Info.plist by path and would describe the old copy of a
    /// bundle replaced at the same path.
    private static func bundleInformation(at bundleURL: URL) -> [String: Any]? {
        let informationURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: informationURL) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    private static func fileIdentity(atPath path: String) -> WidgetExtensionProcessPolicy.FileIdentity? {
        var fileStatus = stat()
        guard stat(path, &fileStatus) == 0 else { return nil }
        return WidgetExtensionProcessPolicy.FileIdentity(
            device: UInt64(UInt32(bitPattern: fileStatus.st_dev)),
            inode: UInt64(fileStatus.st_ino)
        )
    }
}
