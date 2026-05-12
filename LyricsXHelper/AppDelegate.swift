//
//  AppDelegate.swift
//  LyricsX - https://github.com/ddddxxx/LyricsX
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//

import Cocoa
import ScriptingBridge

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {
    var musicPlayers: [SBApplication] = []
    var shouldWaitForPlayerQuit = false

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        guard groupDefaults.bool(forKey: launchAndQuitWithPlayer) else {
            NSApplication.shared.terminate(nil)
            abort() // fake invoking, just make compiler happy.
        }

        let index = groupDefaults.integer(forKey: preferredPlayerIndex)
        let identifiers: [String]
        if playerBundleIdentifiers.indices.contains(index) {
            identifiers = playerBundleIdentifiers[index]
        } else {
            // Auto mode (index = -1) or stale value: listen to every known player.
            identifiers = playerBundleIdentifiers.flatMap { $0 }
        }
        musicPlayers = identifiers.compactMap(SBApplication.init)

        let event = NSAppleEventManager.shared().currentAppleEvent
        let isLaunchedAsLoginItem = event?.eventID == kAEOpenApplication &&
            event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        let isLaunchedByMain = (groupDefaults.object(forKey: launchHelperTime) as? Date).map { Date().timeIntervalSince($0) < 10 } ?? false
        shouldWaitForPlayerQuit = !isLaunchedAsLoginItem && isLaunchedByMain && musicPlayers.contains { $0.isRunning }

        let wsnc = NSWorkspace.shared.notificationCenter
        wsnc.addObserver(self, selector: #selector(checkTargetApplication), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        wsnc.addObserver(self, selector: #selector(checkTargetApplication), name: NSWorkspace.didTerminateApplicationNotification, object: nil)

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

    func launchMainAndQuit() -> Never {
        var host = Bundle.main.bundleURL
        for _ in 0 ..< 4 {
            host.deleteLastPathComponent()
        }

        NSWorkspace.shared.openApplication(at: host, configuration: .init()) { app, error in
            if let error {
                NSLog("launch LyricsX failed. reason: \(error)")
            } else {
                NSLog("launch LyricsX succeed.")
            }
        }
        
        NSApp.terminate(nil)
        abort() // fake invoking, just make compiler happy.
    }
}

let playerBundleIdentifiers = [
    ["com.apple.Music", "com.apple.iTunes"],
    ["com.spotify.client"],
    ["com.coppertino.Vox"],
    ["com.audirvana.Audirvana-Studio", "com.audirvana.Audirvana", "com.audirvana.Audirvana-Plus", "com.audirvana.Audirvana-Origin"],
    ["com.swinsian.Swinsian"],
]

#if DEBUG
let groupDefaults = UserDefaults(suiteName: "D5Q73692VW.group.dev.JH.LyricsX")!
#else
let groupDefaults = UserDefaults(suiteName: "D5Q73692VW.group.com.JH.LyricsX")!
#endif

// Preference
let preferredPlayerIndex = "PreferredPlayerIndex"
let launchAndQuitWithPlayer = "LaunchAndQuitWithPlayer"
let launchHelperTime = "launchHelperTime"
