import Foundation

@main private enum PhoneArtworkMetadataProbe {
    static func main() {
        var count = 0
        func check(_ value: Bool, _ message: String) {
            guard value else { fatalError(message) }
            count += 1
            print("PASS: \(message)")
        }
        check(PhoneArtworkMetadata.simplified("不醉不會") == "不醉不会", "traditional title matches phone spelling")
        check(PhoneArtworkMetadata.simplified("田馥甄") == "田馥甄", "artist spelling is preserved")
        check(PhoneArtworkMetadata.simplified("Ariana Grande") == "Ariana Grande", "Latin names are unchanged")
        check(PhoneArtworkMetadata.simplified(nil) == nil, "missing names stay missing")
        check(PhoneArtworkMetadata.fallbackCountry(title: "不醉不会", artist: "田馥甄", configuredCountry: nil) == "tw", "Chinese metadata gets a bounded catalogue fallback")
        check(PhoneArtworkMetadata.fallbackCountry(title: "不醉不会", artist: "田馥甄", configuredCountry: " TW ") == nil, "configured Chinese catalogue is not queried twice")
        check(PhoneArtworkMetadata.fallbackCountry(title: "Song", artist: "Artist", configuredCountry: nil) == nil, "Latin-only metadata does not add a regional search")
        check(PhoneArtworkMetadata.fallbackCountry(title: nil, artist: nil, configuredCountry: nil) == nil, "empty metadata does not trigger a regional search")
        // Actual catalogue regression: US returns translated aliases; TW returns
        // the original title and artist for the 231.554-second studio recording.
        check(!HighResolutionArtworkPolicy.metadataMatches(candidateTitle: "Learning From Drunk", candidateArtist: "Hebe Tien", candidateDuration: 231.554, trackTitle: "不醉不会", trackArtist: "田馥甄", trackDuration: 231), "unverified translated aliases remain rejected")
        check(HighResolutionArtworkPolicy.metadataMatches(candidateTitle: PhoneArtworkMetadata.simplified("不醉不會"), candidateArtist: "田馥甄", candidateDuration: 231.554, trackTitle: "不醉不会", trackArtist: "田馥甄", trackDuration: 231), "Chinese catalogue recording passes the existing duration and identity checks")
        check(!HighResolutionArtworkPolicy.metadataMatches(candidateTitle: "不醉不会", candidateArtist: "劉大江", candidateDuration: 231, trackTitle: "不醉不会", trackArtist: "田馥甄", trackDuration: 231), "different singer remains rejected")
        check(!HighResolutionArtworkPolicy.metadataMatches(candidateTitle: "不醉不会", candidateArtist: "田馥甄", candidateDuration: 245, trackTitle: "不醉不会", trackArtist: "田馥甄", trackDuration: 231), "different recording length remains rejected")
        print("\(count) checks passed")
    }
}
