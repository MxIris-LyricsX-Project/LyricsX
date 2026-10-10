import Foundation
import Testing
@testable import LyricsXFoundation

struct QQMusicClientTrackResolverTests {
    private func identity(album: String = "Album", source: String = "com.tencent.QQMusicMac") -> ClientPlaybackIdentity {
        .init(sourceBundleIdentifier: source, title: "Song", album: album, artist: "Singer", duration: 208)
    }
    private func archive(ids: [Int] = [123], mid: String = "004HzGmV3n22vM") -> [String: Any] {
        let songs: [[String: Any]] = ids.map { id in
            ["songId": id, "song_Mid": mid, "songName": "Song", "song_Duration": 208.0,
             "albumInfo": ["name": "Album"], "singerList": ["NS.objects": [["name": "Singer"]]]]
        }
        return ["$objects": ["$null", ["ListData": ["CF$UID": 2]], ["NS.objects": songs]],
                "$top": ["PlayingList": ["CF$UID": 1], "LastPlayingIndex": 999]]
    }
    @Test func resolvesExactUniqueQueueSongDespiteStaleIndex() throws {
        let json = try #require(QQMusicClientTrackResolver.resolve(archive: archive(), matching: identity()))
        let song = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(song["id"] as? String == "123")
        #expect(song["mid"] as? String == "004HzGmV3n22vM")
    }
    @Test func ambiguityAndMismatchedMetadataFailClosed() {
        #expect(QQMusicClientTrackResolver.resolve(archive: archive(ids: [123, 456]), matching: identity()) == nil)
        #expect(QQMusicClientTrackResolver.resolve(archive: archive(), matching: identity(album: "Live")) == nil)
        #expect(QQMusicClientTrackResolver.resolve(archive: archive(), matching: identity(source: "com.netease.163music")) == nil)
        #expect(QQMusicClientTrackResolver.resolve(archive: archive(mid: "bad&query=1"), matching: identity()) == nil)
        #expect(QQMusicClientTrackResolver.resolve(archive: archive(ids: [0]), matching: identity()) == nil)
    }
    @Test func duplicateSameSongIsUnambiguousAndBrokenReferencesAreRejected() {
        #expect(QQMusicClientTrackResolver.resolve(archive: archive(ids: [123, 123]), matching: identity()) != nil)
        var broken = archive(); broken["$top"] = ["PlayingList": ["CF$UID": -1]]
        #expect(QQMusicClientTrackResolver.resolve(archive: broken, matching: identity()) == nil)
    }
    @Test func readsPropertyListWithoutChangingClientArchive() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("PlayingList.archive")
        let bytes = try PropertyListSerialization.data(fromPropertyList: archive(), format: .binary, options: 0)
        try bytes.write(to: url)
        #expect(QQMusicClientTrackResolver.currentSong(matching: identity(), archiveURL: url) != nil)
        #expect(try Data(contentsOf: url) == bytes)
        #expect(QQMusicClientTrackResolver.currentSong(matching: identity(), archiveURL: directory.appendingPathComponent("missing")) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("missing").path))
    }
}
