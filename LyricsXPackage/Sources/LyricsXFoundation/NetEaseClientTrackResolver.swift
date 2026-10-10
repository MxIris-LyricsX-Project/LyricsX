import Foundation
import SQLite3
import CoreFoundation

public enum NetEaseClientTrackResolver {
    public static let exactSongKey = "neteaseExactSong"
    public static var databaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.netease.163music/Documents/storage/sqlite_storage.sqlite3")
    }

    struct Record {
        let rowID: String
        let json: String
    }

    public static func isNetEase(_ identity: ClientPlaybackIdentity) -> Bool {
        identity.sourceBundleIdentifier == "com.netease.163music"
    }

    /// Reads a short snapshot with no schema changes, writes or file creation.
    /// SQLite owns all locks, and the connection is closed before networking.
    public static func currentSong(matching identity: ClientPlaybackIdentity, databaseURL: URL = databaseURL, stateDirectory: URL? = nil) -> String? {
        guard isNetEase(identity), let currentID = NetEasePlaybackState.currentSongID(directory: stateDirectory ?? NetEasePlaybackState.directoryURL) else { return nil }
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 25)
        var statement: OpaquePointer?
        let query = "SELECT id, jsonStr FROM dbTrack WHERE id = ?"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        let idText = String(currentID)
        guard idText.withCString({ sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }) == SQLITE_OK else { return nil }
        var records: [Record] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW,
                  let id = sqlite3_column_text(statement, 0),
                  let json = sqlite3_column_text(statement, 1) else { return nil }
            records.append(Record(rowID: String(cString: id), json: String(cString: json)))
        }
        return resolve(records: records, matching: identity, currentID: currentID)
    }

    static func resolve(records: [Record], matching identity: ClientPlaybackIdentity, currentID: Int64) -> String? {
        guard isNetEase(identity), currentID > 0,
              let record = records.first(where: { Int64($0.rowID) == currentID }),
              let song = normalizedSong(record), matches(song, identity),
              let data = try? JSONSerialization.data(withJSONObject: song, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func integer(_ value: Any?) -> Int64? {
        if let string = value as? String { return Int64(string) }
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let result = number.int64Value
            return number.doubleValue == Double(result) ? result : nil
        }
        return nil
    }

    private static func normalizedSong(_ record: Record) -> [String: Any]? {
        guard let raw = try? JSONSerialization.jsonObject(with: Data(record.json.utf8)) as? [String: Any],
              let id = integer(raw["id"]), id > 0, Int64(record.rowID) == id,
              let title = raw["name"] as? String, !title.isEmpty,
              let duration = integer(raw["duration"]), duration > 0,
              let artists = raw["artists"] as? [[String: Any]], !artists.isEmpty,
              let album = raw["album"] as? [String: Any],
              let albumName = album["name"] as? String, !albumName.isEmpty else { return nil }
        var names: [[String: Any]] = []
        for artist in artists {
            guard let name = artist["name"] as? String, !name.isEmpty else { return nil }
            names.append(["id": integer(artist["id"]) ?? 0, "name": name])
        }
        var normalizedAlbum: [String: Any] = ["id": integer(album["id"]) ?? 0, "name": albumName]
        if let artwork = album["picUrl"] as? String, let url = URL(string: artwork),
           ["https", "http"].contains(url.scheme ?? "") { normalizedAlbum["picUrl"] = artwork }
        return ["id": id, "name": title, "duration": duration, "artists": names, "album": normalizedAlbum]
    }

    private static func matches(_ song: [String: Any], _ identity: ClientPlaybackIdentity) -> Bool {
        func trim(_ value: String?) -> String { value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        guard let duration = identity.duration, duration.isFinite, duration > 0,
              !trim(identity.title).isEmpty, !trim(identity.album).isEmpty, !trim(identity.artist).isEmpty,
              trim(identity.title) == trim(song["name"] as? String),
              let album = song["album"] as? [String: Any], trim(identity.album) == trim(album["name"] as? String),
              let milliseconds = song["duration"] as? Int64,
              abs(Double(milliseconds) / 1000 - duration) <= 0.5,
              let artists = song["artists"] as? [[String: Any]] else { return false }
        let names = artists.compactMap { $0["name"] as? String }
        // Only formatting between complete artist names differs. No fuzzy
        // title matching, suffix stripping or album substitution is allowed.
        return ["/", " / ", ", ", "、", " & "].contains { names.joined(separator: $0) == trim(identity.artist) }
    }
}
