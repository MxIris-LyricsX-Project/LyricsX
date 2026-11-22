import Foundation
import Testing
@testable import LyricsXFoundation

// The Lab pane shows where the Apple Music token check stands (issue #223:
// nothing told a user whether the pasted media-user-token worked). The same
// check decides whether Apple Music lyrics are searched at all.

@Test(arguments: [
    (AppleMusicTokenCheck.noToken, false),
    (AppleMusicTokenCheck.checking, false),
    (AppleMusicTokenCheck.finished(.authorized(storefront: "jp")), true),
    (AppleMusicTokenCheck.finished(.denied), false),
    (AppleMusicTokenCheck.finished(.couldNotDetermine(reason: "The Internet connection appears to be offline.")), false),
])
func onlyAnAuthorizedCheckIncludesAppleMusicLyrics(check: AppleMusicTokenCheck, includesAppleMusicLyrics: Bool) {
    #expect(check.includesAppleMusicLyrics == includesAppleMusicLyrics)
}

@Test(arguments: [
    (storefront: "jp", localeIdentifier: "zh-Hans", expected: "日本"),
    (storefront: "us", localeIdentifier: "en", expected: "United States"),
    (storefront: "de", localeIdentifier: "fr", expected: "Allemagne"),
])
func storefrontShowsAsTheRegionNameInTheLocale(storefront: String, localeIdentifier: String, expected: String) {
    let name = AppleMusicTokenCheck.regionName(forStorefront: storefront, locale: Locale(identifier: localeIdentifier))
    #expect(name == expected)
}

@Test
func unknownStorefrontShowsItsIdentifier() {
    #expect(AppleMusicTokenCheck.regionName(forStorefront: "zz9", locale: Locale(identifier: "en")) == "zz9")
}
