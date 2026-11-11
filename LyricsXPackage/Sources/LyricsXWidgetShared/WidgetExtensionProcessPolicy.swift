import Foundation

/// Which running widget extension processes belong to an app that is no longer
/// installed.
///
/// An update replaces the app bundle while its widget extension runs, and
/// nothing ends that process: the system goes on sending it the widget's
/// requests, so the desktop keeps showing what the old version draws until the
/// user logs out. When the new version reads its widgets differently, the old
/// code fails every request and the widgets go black. The app ends such
/// processes when it launches; the system starts the installed extension at
/// the next request. `Documentations/Internal/DesktopWidget.md` has the case.
public enum WidgetExtensionProcessPolicy {
    /// One file, told apart from another that later took its path.
    public struct FileIdentity: Hashable, Sendable {
        public let device: UInt64
        public let inode: UInt64

        public init(device: UInt64, inode: UInt64) {
            self.device = device
            self.inode = inode
        }
    }

    /// The widget extension inside the running app's bundle.
    public struct InstalledExtension: Sendable {
        public let executablePath: String
        public let executableFile: FileIdentity
        public let bundleIdentifier: String
        public let bundleVersion: String

        public init(executablePath: String, executableFile: FileIdentity, bundleIdentifier: String, bundleVersion: String) {
            self.executablePath = executablePath
            self.executableFile = executableFile
            self.bundleIdentifier = bundleIdentifier
            self.bundleVersion = bundleVersion
        }
    }

    /// What is at a running process's executable path now.
    public enum FileAtPath: Equatable, Sendable {
        case missing
        /// The bundle the executable belongs to, as far as its Info.plist says.
        case present(bundleIdentifier: String?, bundleVersion: String?)
    }

    /// What the app can find out about another running process.
    public struct RunningProcess: Sendable {
        public let processIdentifier: Int32
        /// Where the system says the process's executable is. A process whose
        /// file was deleted still reports the file's last path.
        public let executablePath: String
        /// The file the process runs, or `nil` when it could not be read.
        public let executableFile: FileIdentity?
        public let fileAtPath: FileAtPath

        public init(processIdentifier: Int32, executablePath: String, executableFile: FileIdentity?, fileAtPath: FileAtPath) {
            self.processIdentifier = processIdentifier
            self.executablePath = executablePath
            self.executableFile = executableFile
            self.fileAtPath = fileAtPath
        }
    }

    /// Whether `process` is a copy of this app's widget extension that an
    /// update left running.
    ///
    /// - At the installed path, a process is stale when it runs a different
    ///   file: the update wrote over the old one.
    /// - Elsewhere, it is stale when its file is gone — Sparkle moves the old
    ///   app aside and deletes it — or is an older version of this widget
    ///   still on disk. Any other widget extension there is left alone: another
    ///   build's, such as a Debug one, a second copy of this version, or a
    ///   newer copy, which is the one the system starts for the widgets.
    public static func isStale(_ process: RunningProcess, installed: InstalledExtension) -> Bool {
        let installedExecutableName = (installed.executablePath as NSString).lastPathComponent
        guard (process.executablePath as NSString).lastPathComponent == installedExecutableName else {
            return false
        }
        if process.executablePath == installed.executablePath {
            guard let executableFile = process.executableFile else { return false }
            return executableFile != installed.executableFile
        }
        switch process.fileAtPath {
        case .missing:
            return true
        case let .present(bundleIdentifier, bundleVersion):
            guard bundleIdentifier == installed.bundleIdentifier, let bundleVersion else { return false }
            return bundleVersion.compare(installed.bundleVersion, options: .numeric) == .orderedAscending
        }
    }
}
