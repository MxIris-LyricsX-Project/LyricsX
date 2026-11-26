import Testing
@testable import LyricsXFoundation

// While a track plays in QQ Music, NetEase Cloud Music, Kugou or Music, lyrics
// from that app's own lyrics source score higher: the app times them against
// the recording it is playing. These pin down which app maps to which source,
// and that the bonus reorders the right song's copies without lifting another
// song above it.

// MARK: - Which app runs which source

@Test(arguments: ["com.tencent.QQMusicMac", "com.tencent.QQMusic", "com.tencent.QQMusic.D5Q73692VW"])
func qqMusicForMacAndForIPadMapToQQMusic(bundleIdentifier: String) {
    #expect(LyricsProviders.ServiceID(playerBundleIdentifier: bundleIdentifier) == .qq)
}

@Test(arguments: ["com.netease.163music", "com.netease.cloudmusic"])
func neteaseCloudMusicMapsToNetEase(bundleIdentifier: String) {
    #expect(LyricsProviders.ServiceID(playerBundleIdentifier: bundleIdentifier) == .netease)
}

@Test(arguments: ["com.kugou.kugou1002", "com.kugou.mac.kugoumusic"])
func kugouAppsMapToKugou(bundleIdentifier: String) {
    #expect(LyricsProviders.ServiceID(playerBundleIdentifier: bundleIdentifier) == .kugou)
}

@Test
func musicMapsToAppleMusic() {
    #expect(LyricsProviders.ServiceID(playerBundleIdentifier: "com.apple.Music") == .appleMusic)
}

@Test(arguments: ["COM.TENCENT.QQMUSICMAC", "com.Tencent.qqmusicmac"])
func bundleIdentifiersMatchIgnoringCase(bundleIdentifier: String) {
    #expect(LyricsProviders.ServiceID(playerBundleIdentifier: bundleIdentifier) == .qq)
}

@Test(arguments: [
    "com.tencent.xinWeChat",
    "com.tencent.meeting",
    "com.netease.mail",
    "com.apple.TV",
    "com.apple.podcasts",
    "com.apple.Music.extension",
])
func otherAppsFromTheSameCompaniesMapToNoSource(bundleIdentifier: String) {
    #expect(LyricsProviders.ServiceID(playerBundleIdentifier: bundleIdentifier) == nil)
}

@Test(arguments: ["com.spotify.client", "com.colliderli.iina", "org.videolan.vlc", "", "qqmusic", "kugou.com.player"])
func unknownPlayersMapToNoSource(bundleIdentifier: String) {
    #expect(LyricsProviders.ServiceID(playerBundleIdentifier: bundleIdentifier) == nil)
}

// MARK: - Whether lyrics belong to the playing app

// The service names are the ones the providers write into
// `Lyrics.Metadata.service`, as the search panel's Source column shows them.
@Test(arguments: [
    ("QQMusic", "com.tencent.QQMusicMac"),
    ("NetEase", "com.netease.163music"),
    ("Kugou", "com.kugou.kugou1002"),
    ("Apple Music", "com.apple.Music"),
])
func lyricsFromThePlayersOwnServiceBelongToIt(service: String, playerBundleIdentifier: String) {
    #expect(PlayerLyricsSourcePolicy.lyricsService(service, belongsToPlayerWithBundleIdentifier: playerBundleIdentifier))
}

@Test(arguments: [
    ("Kugou", "com.tencent.QQMusicMac"),
    ("QQMusic", "com.netease.163music"),
    ("Musixmatch", "com.spotify.client"),
    ("LRCLIB", "com.apple.Music"),
])
func lyricsFromAnotherServiceDoNotBelongToThePlayer(service: String, playerBundleIdentifier: String) {
    #expect(!PlayerLyricsSourcePolicy.lyricsService(service, belongsToPlayerWithBundleIdentifier: playerBundleIdentifier))
}

@Test
func lyricsWithoutAServiceOrWithoutAPlayerBelongToNoPlayer() {
    #expect(!PlayerLyricsSourcePolicy.lyricsService(nil, belongsToPlayerWithBundleIdentifier: "com.tencent.QQMusicMac"))
    #expect(!PlayerLyricsSourcePolicy.lyricsService("QQMusic", belongsToPlayerWithBundleIdentifier: nil))
}

// MARK: - What the bonus does to the ranking

// The scores are the ones the search panel showed for 薛之谦's 一半 while it
// played in QQ Music: Kugou's copy 1.05 ahead of QQ Music's own 0.99, the gap
// being LyricsKit's feature bonuses rather than a worse match. The source
// indices are the default order (NetEase, QQMusic, Kugou, …).
private let qqMusicSourceIndex = 1
private let kugouSourceIndex = 2

@Test(arguments: [LyricsSourceOrderingMode.qualityOnly, .qualityFirstSourceTieBreak])
func playerSourceOutranksAnotherSourceAheadByOneFeatureBonus(mode: LyricsSourceOrderingMode) {
    let outranksWithoutBonus = LyricsSourceOrderingPolicy.hasHigherPriority(
        candidateQuality: 0.99,
        candidateSourceIndex: qqMusicSourceIndex,
        comparedToQuality: 1.05,
        comparedToSourceIndex: kugouSourceIndex,
        mode: mode
    )
    let outranksWithBonus = LyricsSourceOrderingPolicy.hasHigherPriority(
        candidateQuality: 0.99 + PlayerLyricsSourcePolicy.matchBonus,
        candidateSourceIndex: qqMusicSourceIndex,
        comparedToQuality: 1.05,
        comparedToSourceIndex: kugouSourceIndex,
        mode: mode
    )

    #expect(!outranksWithoutBonus && outranksWithBonus, "the bonus is what puts QQ Music's copy first")
}

// In the same results QQ Music's 我好像在哪见过你, another song by the same
// artist, scored 0.59 against Kugou's 0.98 for 一半.
@Test(arguments: [LyricsSourceOrderingMode.qualityOnly, .qualityFirstSourceTieBreak])
func playerSourceDoesNotLiftAnotherSongAboveTheRightOne(mode: LyricsSourceOrderingMode) {
    #expect(!LyricsSourceOrderingPolicy.hasHigherPriority(
        candidateQuality: 0.59 + PlayerLyricsSourcePolicy.matchBonus,
        candidateSourceIndex: qqMusicSourceIndex,
        comparedToQuality: 0.98,
        comparedToSourceIndex: kugouSourceIndex,
        mode: mode
    ))
}
