import Foundation
import os
import LyricsXFoundation

/// One-shot migration of UserDefaults from the sandbox container into the
/// non-sandbox preferences domain after the app drops `com.apple.security.app-sandbox`.
///
/// Sandbox stores prefs at:
///   ~/Library/Containers/<bundleID>/Data/Library/Preferences/<bundleID>.plist
/// Non-sandbox stores prefs at:
///   ~/Library/Preferences/<bundleID>.plist
///
/// `cfprefsd` resolves which file `UserDefaults.standard` reads from based on
/// the running process's sandbox state, so flipping the entitlement makes the
/// container plist invisible. This class copies the values across and records
/// completion in the destination domain so it never runs twice.
@Loggable(subsystem: "com.JH.LyricsX.diagnostics")
final class UserDefaultsMigrator {
    static let shared = UserDefaultsMigrator()

    private static let migrationCompletionKey = "Migration.SandboxToNonSandbox.v1"
    private static let sourceOrderingModeMigrationCompletionKey = "Migration.SourceOrderingMode.v1"

    private let bundleIdentifier: String
    private let userDefaults: UserDefaults
    private let fileManager: FileManager

    init(
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.JH.LyricsX",
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.userDefaults = userDefaults
        self.fileManager = fileManager
    }

    /// Idempotent. Must be called before any other UserDefaults read or
    /// `register(defaults:)` happens — i.e. at the very top of
    /// `applicationDidFinishLaunching(_:)`.
    func migrateFromSandboxIfNeeded() {
        guard !userDefaults.bool(forKey: Self.migrationCompletionKey) else { return }

        let sourceURL = sandboxContainerPlistURL
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            markCompleted()
            #log(.info, "No sandbox container plist found at \(sourceURL.path, privacy: .public); nothing to migrate")
            return
        }

        do {
            let data = try Data(contentsOf: sourceURL)
            guard let dictionary = try PropertyListSerialization
                .propertyList(from: data, options: [], format: nil) as? [String: Any]
            else {
                #log(.error, "Sandbox plist is not a top-level dictionary at \(sourceURL.path, privacy: .public)")
                return
            }

            var migratedKeyCount = 0
            for (key, value) in dictionary where !isSystemKey(key) {
                userDefaults.set(value, forKey: key)
                migratedKeyCount += 1
            }

            markCompleted()
            #log(.info, "Migrated \(migratedKeyCount, privacy: .public) keys from sandbox container at \(sourceURL.path, privacy: .public)")
        } catch {
            #log(.error, "Migration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Seeds `LyricsSourceOrderingMode` from the boolean checkbox it replaced,
    /// so nobody's ranking behaviour changes across the upgrade. The third mode
    /// has no legacy equivalent and is only ever reached by choosing it.
    ///
    /// Idempotent, and — like the sandbox migration — it must run before
    /// `register(defaults:)`. Registered values are visible to
    /// `object(forKey:)`, so registering a default for the new key first would
    /// make it look like the user had already chosen a mode, and the legacy
    /// setting would be silently dropped.
    func migrateSourceOrderingModeIfNeeded() {
        guard !userDefaults.bool(forKey: Self.sourceOrderingModeMigrationCompletionKey) else { return }
        defer { userDefaults.set(true, forKey: Self.sourceOrderingModeMigrationCompletionKey) }

        let orderingModeKey = UserDefaults.DefaultsKeys.lyricsSourceOrderingMode.key
        guard userDefaults.object(forKey: orderingModeKey) == nil else {
            #log(.info, "Ordering mode already set; nothing to seed from the legacy checkbox")
            return
        }

        let legacyKey = UserDefaults.DefaultsKeys.lyricsSourcePriorityEnabled.key
        let legacySourcePriorityEnabled = userDefaults.bool(forKey: legacyKey)
        let mode: LyricsSourceOrderingMode = legacySourcePriorityEnabled ? .sourceFirst : .qualityOnly
        userDefaults.set(mode.rawValue, forKey: orderingModeKey)
        #log(.info, "Seeded ordering mode \(mode.rawValue, privacy: .public) from \(legacyKey, privacy: .public)=\(legacySourcePriorityEnabled, privacy: .public)")
    }

    private var sandboxContainerPlistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Containers/\(bundleIdentifier)/Data/Library/Preferences/\(bundleIdentifier).plist")
    }

    /// Skip framework-internal namespaces. `AppleLanguages` is intentionally
    /// allowed through — it's the user's locale choice and we want to keep it.
    private func isSystemKey(_ key: String) -> Bool {
        key.hasPrefix("NS") || key.hasPrefix("com.apple.")
    }

    private func markCompleted() {
        userDefaults.set(true, forKey: Self.migrationCompletionKey)
    }
}
