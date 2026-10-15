
import Foundation
import Testing
import SQLite3
@testable import LyricsXFoundation

struct NetEaseClientTrackResolverTests {
    @Test func replayMustNotDependOnNewestHistoryRow() {
        #expect(NetEaseClientTrackResolver.resolve(records: [row(id: "456", title: "Previous Song"), row()], matching: track(), currentID: 123) != nil)
    }

    private func track(title: String = "Test Song", artist: String = "A/B", album: String = "Studio", duration: Double = 200) -> ClientPlaybackIdentity {
        ClientPlaybackIdentity(sourceBundleIdentifier: "com.netease.163music", title: title, album: album, artist: artist, duration: duration)
    }
    private func row(id: String = "123", title: String = "Test Song", album: String = "Studio", duration: Int = 200000) -> NetEaseClientTrackResolver.Record {
        let data: [String: Any] = ["id": id, "name": title, "duration": duration,
                                  "artists": [["id": "1", "name": "A"], ["id": "2", "name": "B"]],
                                  "album": ["id": "3", "name": album]]
        let json = String(data: try! JSONSerialization.data(withJSONObject: data), encoding: .utf8)!
        return .init(rowID: id, json: json)
    }
    @Test func acceptsExplicitClientSongAndNormalizesStringIDs() throws {
        let json = try #require(NetEaseClientTrackResolver.resolve(records: [row()], matching: track(), currentID: 123))
        let song = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(song["id"] as? Int == 123)
        #expect(song["name"] as? String == "Test Song")
    }
    @Test func explicitPlaybackIDIgnoresHistoryOrder() {
        #expect(NetEaseClientTrackResolver.resolve(records: [row(id: "456", title: "Previous Song"), row()], matching: track(), currentID: 123) != nil)
    }
    @Test func rejectsVersionsAndIncompletePlaybackMetadata() {
        #expect(NetEaseClientTrackResolver.resolve(records: [row(album: "Live")], matching: track(), currentID: 123) == nil)
        #expect(NetEaseClientTrackResolver.resolve(records: [row(duration: 205000)], matching: track(), currentID: 123) == nil)
        #expect(NetEaseClientTrackResolver.resolve(records: [row()], matching: track(artist: "Other"), currentID: 123) == nil)
        #expect(NetEaseClientTrackResolver.resolve(records: [row()], matching: track(album: ""), currentID: 123) == nil)
        #expect(NetEaseClientTrackResolver.resolve(records: [row()], matching: track(duration: .nan), currentID: 123) == nil)
    }
    @Test func explicitIDDistinguishesIdenticalMetadataAndRejectsBrokenRecords() {
        #expect(NetEaseClientTrackResolver.resolve(records: [row(), row(id: "456")], matching: track(), currentID: 123) != nil)
        #expect(NetEaseClientTrackResolver.resolve(records: [], matching: track(), currentID: 123) == nil)
        #expect(NetEaseClientTrackResolver.resolve(records: [row(id: "invalid")], matching: track(), currentID: 123) == nil)
        let corrupt = NetEaseClientTrackResolver.Record(rowID: "456", json: row().json)
        #expect(NetEaseClientTrackResolver.resolve(records: [corrupt], matching: track(), currentID: 123) == nil)
    }
    @Test func refusesAnotherPlayerEvenWithIdenticalMetadata() {
        var other = track()
        other.sourceBundleIdentifier = "com.spotify.client"
        #expect(NetEaseClientTrackResolver.resolve(records: [row()], matching: other, currentID: 123) == nil)
        other.sourceBundleIdentifier = nil
        #expect(!NetEaseClientTrackResolver.isNetEase(other))
    }
    @Test func databaseLookupReadsExplicitSongWithoutChangingTheDatabase() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("client.sqlite3")
        var db: OpaquePointer?
        #expect(sqlite3_open(path.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "CREATE TABLE dbTrack(id TEXT, playtime INTEGER, jsonStr TEXT)", nil, nil, nil) == SQLITE_OK)
        let json = row().json.replacingOccurrences(of: "'", with: "''")
        #expect(sqlite3_exec(db, "INSERT INTO dbTrack VALUES('123',1000,'\(json)')", nil, nil, nil) == SQLITE_OK)
        let state = directory.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try NetEasePlaybackStateTests.logFixture().write(to: state.appendingPathComponent("000001.log"))
        let before = try Data(contentsOf: path)
        #expect(NetEaseClientTrackResolver.currentSong(matching: track(), databaseURL: path, stateDirectory: state) != nil)
        #expect(try Data(contentsOf: path) == before)
        #expect(NetEaseClientTrackResolver.currentSong(matching: track(), databaseURL: directory.appendingPathComponent("missing"), stateDirectory: state) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("missing").path))
    }
}
