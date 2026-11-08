import Testing
@testable import LyricsXFoundation

/// Stands in for the MusicKit-backed recovery, which needs Apple Music
/// access: it always recovers the same native-script name.
private struct RecoveringNativeName: LyricsSearchRequestPlugin {
    static let nativeName = LyricsSearchRequest.SearchTerm.info(title: "芒种", artist: "赵方婧")

    func additionalRequests(for request: LyricsSearchRequest) async -> [LyricsSearchRequest] {
        [request.derived(searchTerm: Self.nativeName)]
    }
}

private func searchForLocalizedName(isForAppleMusicTrack: Bool) -> LyricsSearchRequest {
    var request = LyricsSearchRequest(
        searchTerm: .info(title: "Mang Zhong", artist: "Listening to Yinque's Poems & Fangji"),
        duration: 216
    )
    request.isForAppleMusicTrack = isForAppleMusicTrack
    return request
}

@Test
func aSearchForATrackPlayingInMusicGetsTheRecoveredName() async {
    let plugin = AppleMusicTrackNameRecoveryPlugin(nameRecovery: RecoveringNativeName())

    let addedRequests = await plugin.additionalRequests(for: searchForLocalizedName(isForAppleMusicTrack: true))

    #expect(addedRequests.map(\.searchTerm) == [RecoveringNativeName.nativeName])
}

@Test
func aSearchForATrackFromAnotherAppGetsNothing() async {
    let plugin = AppleMusicTrackNameRecoveryPlugin(nameRecovery: RecoveringNativeName())

    let addedRequests = await plugin.additionalRequests(for: searchForLocalizedName(isForAppleMusicTrack: false))

    #expect(addedRequests.isEmpty)
}

@Test
func aNewSearchIsNotForAnAppleMusicTrack() {
    let request = LyricsSearchRequest(searchTerm: .keyword("Mang Zhong"), duration: 216)

    #expect(!request.isForAppleMusicTrack)
}

@Test
func unmarkingASearchLeavesItAsIfItHadNeverBeenMarked() {
    let unmarkedRequest = LyricsSearchRequest(searchTerm: .keyword("Mang Zhong"), duration: 216)
    var request = unmarkedRequest

    request.isForAppleMusicTrack = true
    request.isForAppleMusicTrack = false

    #expect(request == unmarkedRequest)
}
