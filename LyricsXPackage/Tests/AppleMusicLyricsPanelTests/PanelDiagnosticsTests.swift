import Foundation
import Testing
@testable import AppleMusicLyricsPanel

/// The panel's logging and signposting hang off one switch. These pin the
/// contract that matters for a shipping build: nothing is on unless somebody
/// asked, either the environment or the defaults key is enough to ask, and a
/// group list turns on exactly the groups named.
struct PanelDiagnosticsTests {
    private typealias Diagnostics = AppleMusicLyrics.PanelDiagnostics

    private static func makeIsolatedDefaults() throws -> UserDefaults {
        let suiteName = "dev.JH.LyricsX.PanelDiagnosticsTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        return userDefaults
    }

    @Test func diagnosticsAreOffUnlessAsked() throws {
        let userDefaults = try Self.makeIsolatedDefaults()
        #expect(!Diagnostics.resolveIsEnabled(environment: [:], userDefaults: userDefaults))
        #expect(Diagnostics.resolveEnabledGroups(environment: [:], userDefaults: userDefaults).isEmpty)
        #expect(!Diagnostics.resolveIsEnabled(
            environment: [Diagnostics.environmentKey: "0"],
            userDefaults: userDefaults
        ))
    }

    @Test func theEnvironmentVariableTurnsEverythingOn() throws {
        let userDefaults = try Self.makeIsolatedDefaults()
        #expect(Diagnostics.resolveIsEnabled(
            environment: [Diagnostics.environmentKey: "1"],
            userDefaults: userDefaults
        ))
        #expect(Diagnostics.resolveEnabledGroups(
            environment: [Diagnostics.environmentKey: "1"],
            userDefaults: userDefaults
        ) == .all)
        #expect(Diagnostics.resolveEnabledGroups(
            environment: [Diagnostics.environmentKey: "all"],
            userDefaults: userDefaults
        ) == .all)
    }

    @Test func theDefaultsKeyTurnsDiagnosticsOn() throws {
        let userDefaults = try Self.makeIsolatedDefaults()
        userDefaults.set(true, forKey: Diagnostics.userDefaultsKey)
        #expect(Diagnostics.resolveIsEnabled(environment: [:], userDefaults: userDefaults))
        #expect(Diagnostics.resolveEnabledGroups(environment: [:], userDefaults: userDefaults) == .all)
        userDefaults.set(false, forKey: Diagnostics.userDefaultsKey)
        #expect(!Diagnostics.resolveIsEnabled(environment: [:], userDefaults: userDefaults))
        userDefaults.set("lyrics, karaoke", forKey: Diagnostics.userDefaultsKey)
        #expect(Diagnostics.resolveEnabledGroups(environment: [:], userDefaults: userDefaults) == [.lyrics, .karaoke])
    }

    @Test func aGroupListTurnsOnExactlyThoseGroups() throws {
        let userDefaults = try Self.makeIsolatedDefaults()
        #expect(Diagnostics.parseGroups("lyrics") == .lyrics)
        #expect(Diagnostics.parseGroups("backdrop") == .backdrop)
        #expect(Diagnostics.parseGroups("Lyrics,KARAOKE") == [.lyrics, .karaoke])
        #expect(Diagnostics.parseGroups("lyrics karaoke backdrop") == .all)
        #expect(Diagnostics.parseGroups("lyrics, nonsense") == .lyrics)
        #expect(Diagnostics.parseGroups("nonsense").isEmpty)
        #expect(Diagnostics.parseGroups("off").isEmpty)
        #expect(Diagnostics.resolveEnabledGroups(
            environment: [Diagnostics.environmentKey: "backdrop"],
            userDefaults: userDefaults
        ) == .backdrop)
    }

    @Test func theEnvironmentOverridesTheDefaultsKey() throws {
        let userDefaults = try Self.makeIsolatedDefaults()
        userDefaults.set(true, forKey: Diagnostics.userDefaultsKey)
        #expect(Diagnostics.resolveEnabledGroups(
            environment: [Diagnostics.environmentKey: "karaoke"],
            userDefaults: userDefaults
        ) == .karaoke)
        #expect(Diagnostics.resolveEnabledGroups(
            environment: [Diagnostics.environmentKey: "0"],
            userDefaults: userDefaults
        ).isEmpty)
        // An empty environment value is the same as no value at all.
        #expect(Diagnostics.resolveEnabledGroups(
            environment: [Diagnostics.environmentKey: ""],
            userDefaults: userDefaults
        ) == .all)
    }
}
