import Foundation
import CoreFoundation

/// Reads QQ Music's keyed archive as a property list, without instantiating
/// archived Objective-C classes. The saved index can lag live playback, so
/// only a unique full-metadata match inside the client's queue is accepted.
public enum QQMusicClientTrackResolver {
    public static let exactSongKey = "qqmusicExactSong"
    public static var archiveURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Containers/com.tencent.QQMusicMac/Data/Library/Application Support/QQMusicMac/iTemp/PlayingList.archive")
    }
    public static func isQQMusic(_ identity: ClientPlaybackIdentity) -> Bool {
        identity.sourceBundleIdentifier == "com.tencent.QQMusicMac"
    }
    public static func currentSong(matching identity: ClientPlaybackIdentity, archiveURL: URL = archiveURL) -> String? {
        // Rename the XML UID key before reparsing so Foundation keeps it as
        // a plain dictionary instead of constructing an opaque UID object.
        guard isQQMusic(identity), let size = try? archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 16 * 1024 * 1024, let data = try? Data(contentsOf: archiveURL),
              let raw = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let xml = try? PropertyListSerialization.data(fromPropertyList: raw, format: .xml, options: 0),
              xml.count <= 64 * 1024 * 1024,
              let xmlString = String(data: xml, encoding: .utf8),
              let archive = try? PropertyListSerialization.propertyList(
                from: Data(xmlString.replacingOccurrences(of: "<key>CF$UID</key>", with: "<key>LyricsXUID</key>").utf8),
                options: [], format: nil) as? [String: Any] else { return nil }
        return resolve(archive: archive, matching: identity)
    }

    static func resolve(archive: [String: Any], matching identity: ClientPlaybackIdentity) -> String? {
        guard isQQMusic(identity), let objects = archive["$objects"] as? [Any], objects.count <= 50000,
              let top = archive["$top"] as? [String: Any] else { return nil }
        func object(_ value: Any?) -> Any? {
            guard let ref = value as? [String: Any], let index = (ref["LyricsXUID"] ?? ref["CF$UID"]) as? NSNumber else { return value }
            guard CFGetTypeID(index) != CFBooleanGetTypeID(), index.doubleValue == Double(index.intValue),
                  index.intValue >= 0, index.intValue < objects.count else { return nil }
            return objects[index.intValue]
        }
        func text(_ value: Any?) -> String? {
            guard let value = object(value) as? String, value != "$null", !value.isEmpty else { return nil }
            return value
        }
        guard let list = object(top["PlayingList"]) as? [String: Any],
              let data = object(list["ListData"]) as? [String: Any], let rows = data["NS.objects"] as? [Any],
              let duration = identity.duration, duration.isFinite, duration > 0 else { return nil }
        var matched: [String: [String: Any]] = [:]
        for reference in rows {
            guard let song = object(reference) as? [String: Any],
                  let id = object(song["songId"]) as? NSNumber, CFGetTypeID(id) != CFBooleanGetTypeID(),
                  id.int64Value > 0, id.doubleValue == Double(id.int64Value),
                  let mid = text(song["song_Mid"]), mid.range(of: "^[A-Za-z0-9]{1,64}$", options: .regularExpression) != nil,
                  let name = text(song["songName"]), name == identity.title,
                  let length = object(song["song_Duration"]) as? NSNumber, length.doubleValue.isFinite,
                  abs(length.doubleValue - duration) <= 0.5,
                  let album = object(song["albumInfo"]) as? [String: Any], let albumName = text(album["name"]), albumName == identity.album,
                  let singers = object(song["singerList"]) as? [String: Any], let singerRefs = singers["NS.objects"] as? [Any], !singerRefs.isEmpty else { continue }
            let names = singerRefs.compactMap { ref -> String? in
                guard let singer = object(ref) as? [String: Any] else { return nil }
                return text(singer["name"])
            }
            guard names.count == singerRefs.count,
                  ["/", " / ", ",", ", ", "、", " & "].contains(where: { names.joined(separator: $0) == identity.artist }) else { continue }
            let record: [String: Any] = ["id": id.stringValue, "mid": mid, "name": name, "album": albumName,
                                         "singers": names, "duration": length.doubleValue]
            matched[id.stringValue + ":" + mid] = record
        }
        guard matched.count == 1, let song = matched.values.first,
              let data = try? JSONSerialization.data(withJSONObject: song, options: .sortedKeys) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
