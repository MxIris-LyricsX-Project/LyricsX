import Testing
@testable import LyricsXWidgetShared

// An update replaces the app bundle under a running widget extension, and the
// system keeps handing the widget's requests to that process. On 2026-10-28
// a 1.9.0-beta.14 extension started at login went on answering for rc.1 after
// Sparkle installed it, and refused every request rc.1's widgets made: the
// desktop widgets stayed black until the process was ended. The app ends such
// a process when it launches; these pin down which processes count.

@Suite("Widget extension process policy")
struct WidgetExtensionProcessPolicyTests {
    private typealias Policy = WidgetExtensionProcessPolicy

    private static let installedPath =
        "/Applications/LyricsX.app/Contents/PlugIns/LyricsXWidget.appex/Contents/MacOS/LyricsXWidget"

    private static let installed = Policy.InstalledExtension(
        executablePath: installedPath,
        executableFile: Policy.FileIdentity(device: 16_777_232, inode: 632_722_553),
        bundleIdentifier: "com.JH.LyricsX.LyricsWidget",
        bundleVersion: "10900201"
    )

    @Test("a process running the installed extension is left alone")
    func installedExtensionIsLeftAlone() {
        let process = Policy.RunningProcess(
            processIdentifier: 81033,
            executablePath: Self.installedPath,
            executableFile: Self.installed.executableFile,
            fileAtPath: .present(bundleIdentifier: "com.JH.LyricsX.LyricsWidget", bundleVersion: "10900201")
        )

        #expect(!Policy.isStale(process, installed: Self.installed))
    }

    @Test("a process whose bundle the update moved away and deleted is ended")
    func processFromADeletedBundleIsEnded() {
        // Sparkle moves the old app into its installation directory, puts the
        // new one in its place and deletes the old one; the process goes on
        // running the deleted file, which the system reports at its last path.
        let process = Policy.RunningProcess(
            processIdentifier: 896,
            executablePath: "/Users/someone/Library/Caches/com.JH.LyricsX/org.sparkle-project.Sparkle/Installation/"
                + "A1B2C3/LyricsX.app/Contents/PlugIns/LyricsXWidget.appex/Contents/MacOS/LyricsXWidget",
            executableFile: Policy.FileIdentity(device: 16_777_232, inode: 630_000_001),
            fileAtPath: .missing
        )

        #expect(Policy.isStale(process, installed: Self.installed))
    }

    @Test("a process whose executable an update wrote over in place is ended")
    func processWhoseExecutableWasReplacedInPlaceIsEnded() {
        // Copying the new app over the old one keeps the path; only the file
        // the process runs tells the two apart.
        let process = Policy.RunningProcess(
            processIdentifier: 512,
            executablePath: Self.installedPath,
            executableFile: Policy.FileIdentity(device: 16_777_232, inode: 630_000_001),
            fileAtPath: .present(bundleIdentifier: "com.JH.LyricsX.LyricsWidget", bundleVersion: "10900201")
        )

        #expect(Policy.isStale(process, installed: Self.installed))
    }

    @Test("an older copy of this widget still on disk is ended")
    func olderCopyStillOnDiskIsEnded() {
        let process = Policy.RunningProcess(
            processIdentifier: 640,
            executablePath: "/Users/someone/Library/Caches/com.JH.LyricsX/org.sparkle-project.Sparkle/Installation/"
                + "A1B2C3/LyricsX.app/Contents/PlugIns/LyricsXWidget.appex/Contents/MacOS/LyricsXWidget",
            executableFile: Policy.FileIdentity(device: 16_777_232, inode: 630_000_001),
            fileAtPath: .present(bundleIdentifier: "com.JH.LyricsX.LyricsWidget", bundleVersion: "10900114")
        )

        #expect(Policy.isStale(process, installed: Self.installed))
    }

    @Test("a newer copy of this widget elsewhere is left alone")
    func newerCopyElsewhereIsLeftAlone() {
        // Shaped on 2026-10-28: a 2929 Debug build ended the 2930 Debug build's
        // widget that the system had just started, and the system started it
        // again. A newer copy is the one the system prefers, not a leftover.
        let process = Policy.RunningProcess(
            processIdentifier: 22579,
            executablePath: "/Volumes/DerivedData/MxIris-LyricsX-Project/Build/Products/Debug/LyricsX-Debug.app"
                + "/Contents/PlugIns/LyricsXWidget.appex/Contents/MacOS/LyricsXWidget",
            executableFile: Policy.FileIdentity(device: 16_777_271, inode: 53_953_332),
            fileAtPath: .present(bundleIdentifier: "com.JH.LyricsX.LyricsWidget", bundleVersion: "10900300")
        )

        #expect(!Policy.isStale(process, installed: Self.installed))
    }

    @Test("a copy of this widget whose version cannot be read is left alone")
    func copyWithAnUnreadableVersionIsLeftAlone() {
        let process = Policy.RunningProcess(
            processIdentifier: 23000,
            executablePath: "/Users/someone/Downloads/LyricsX.app/Contents/PlugIns/LyricsXWidget.appex/Contents/MacOS/LyricsXWidget",
            executableFile: Policy.FileIdentity(device: 16_777_232, inode: 700_000_002),
            fileAtPath: .present(bundleIdentifier: "com.JH.LyricsX.LyricsWidget", bundleVersion: nil)
        )

        #expect(!Policy.isStale(process, installed: Self.installed))
    }

    @Test("another build's widget extension is left alone")
    func anotherBuildsWidgetIsLeftAlone() {
        // A Debug build has a widget of its own, with its own bundle
        // identifier, that the desktop may be showing next to this one.
        let process = Policy.RunningProcess(
            processIdentifier: 1285,
            executablePath: "/Volumes/DerivedData/LyricsX/Build/Products/Debug/LyricsX-Debug.app"
                + "/Contents/PlugIns/LyricsXWidget.appex/Contents/MacOS/LyricsXWidget",
            executableFile: Policy.FileIdentity(device: 16_777_233, inode: 42_908_533),
            fileAtPath: .present(bundleIdentifier: "dev.JH.LyricsX.LyricsWidget", bundleVersion: "2929")
        )

        #expect(!Policy.isStale(process, installed: Self.installed))
    }

    @Test("a second copy of the installed version is left alone")
    func secondCopyOfTheInstalledVersionIsLeftAlone() {
        let process = Policy.RunningProcess(
            processIdentifier: 700,
            executablePath: "/Users/someone/Downloads/LyricsX.app/Contents/PlugIns/LyricsXWidget.appex/Contents/MacOS/LyricsXWidget",
            executableFile: Policy.FileIdentity(device: 16_777_232, inode: 700_000_001),
            fileAtPath: .present(bundleIdentifier: "com.JH.LyricsX.LyricsWidget", bundleVersion: "10900201")
        )

        #expect(!Policy.isStale(process, installed: Self.installed))
    }

    @Test("a process at the installed path whose file cannot be told is left alone")
    func processWithAnUnknownFileIsLeftAlone() {
        let process = Policy.RunningProcess(
            processIdentifier: 81033,
            executablePath: Self.installedPath,
            executableFile: nil,
            fileAtPath: .present(bundleIdentifier: "com.JH.LyricsX.LyricsWidget", bundleVersion: "10900201")
        )

        #expect(!Policy.isStale(process, installed: Self.installed))
    }

    @Test("a process that is not a widget extension is left alone")
    func processThatIsNotTheWidgetIsLeftAlone() {
        let process = Policy.RunningProcess(
            processIdentifier: 900,
            executablePath: "/Users/someone/Library/Caches/com.JH.LyricsX/org.sparkle-project.Sparkle/Installation/"
                + "A1B2C3/LyricsX.app/Contents/MacOS/LyricsX",
            executableFile: Policy.FileIdentity(device: 16_777_232, inode: 630_000_002),
            fileAtPath: .missing
        )

        #expect(!Policy.isStale(process, installed: Self.installed))
    }
}
