import Cocoa
import ScriptingBridge

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    var musicPlayers: [SBApplication] = []
    var shouldWaitForPlayerQuit = false

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        guard sharedDefaults.bool(forKey: launchAndQuitWithPlayer) else {
            NSApplication.shared.terminate(nil)
            abort() // fake invoking, just make compiler happy.
        }

        let index = sharedDefaults.integer(forKey: preferredPlayerIndex)
        let identifiers: [String] = if playerBundleIdentifiers.indices.contains(index) {
            playerBundleIdentifiers[index]
        } else {
            // Auto mode (index = -1) or stale value: listen to every known player.
            playerBundleIdentifiers.flatMap { $0 }
        }
        musicPlayers = identifiers.compactMap(SBApplication.init)

        let event = NSAppleEventManager.shared().currentAppleEvent
        let isLaunchedAsLoginItem = event?.eventID == kAEOpenApplication &&
            event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        let isLaunchedByMain = (sharedDefaults.object(forKey: launchHelperTime) as? Date).map { Date().timeIntervalSince($0) < 10 } ?? false
        shouldWaitForPlayerQuit = !isLaunchedAsLoginItem && isLaunchedByMain && musicPlayers.contains { $0.isRunning }

        let wsnc = NSWorkspace.shared.notificationCenter
        wsnc.addObserver(self, selector: #selector(checkTargetApplication), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        wsnc.addObserver(self, selector: #selector(checkTargetApplication), name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        // Sudden termination would let the system kill this background agent
        // without ever consulting `applicationShouldTerminate(_:)`. Disable it
        // so the login window's quiet-quit is routed through that delegate,
        // where we refuse it and stay resident.
        ProcessInfo.processInfo.disableSuddenTermination()

        checkTargetApplication()
    }

    @objc func checkTargetApplication() {
        let isRunning = musicPlayers.contains { $0.isRunning }
        if shouldWaitForPlayerQuit {
            shouldWaitForPlayerQuit = isRunning
            return
        } else if isRunning {
            launchMainAndQuit()
        }
    }

    func launchMainAndQuit() {
        var host = Bundle.main.bundleURL
        for _ in 0 ..< 4 {
            host.deleteLastPathComponent()
        }
        NSWorkspace.shared.openApplication(at: host, configuration: .init()) { [weak self] app, error in
            defer {
                NSApp.terminate(nil)
                abort() // fake invoking, just make compiler happy.
            }

            guard let self else { return }

            if let error {
                NSLog("launch LyricsX failed. reason: \(error)")
            } else {
                NSLog("launch LyricsX succeed.")
            }
        }
    }
}

let playerBundleIdentifiers = [
    ["com.apple.Music", "com.apple.iTunes"],
    ["com.spotify.client"],
    ["com.coppertino.Vox"],
    ["com.audirvana.Audirvana-Studio", "com.audirvana.Audirvana", "com.audirvana.Audirvana-Plus", "com.audirvana.Audirvana-Origin"],
    ["com.swinsian.Swinsian"],
]

// Shared with the main app via a plain preferences suite under
// ~/Library/Preferences. NOT an App Group container — this helper is
// non-sandboxed and cfprefsd rejects App Group preference reads from
// non-sandboxed processes ("kCFPreferencesAnyUser ... only allowed for System
// Containers"). Must match `lyricsXSharedSuiteName` in the main app's Global.swift.
#if DEBUG
let sharedDefaults = UserDefaults(suiteName: "dev.JH.LyricsX.shared")!
#else
let sharedDefaults = UserDefaults(suiteName: "com.JH.LyricsX.shared")!
#endif

// Preference
let preferredPlayerIndex = "PreferredPlayerIndex"
let launchAndQuitWithPlayer = "LaunchAndQuitWithPlayer"
let launchHelperTime = "launchHelperTime"
