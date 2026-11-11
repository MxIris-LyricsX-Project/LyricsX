import Foundation

/// Remembers, per track, which lyrics file the user picked by hand.
///
/// Automatic lookup has a fixed order: lyrics embedded in the audio file, then
/// lyrics sitting beside it, then the saving directory. A candidate the user
/// switched to gets written into the saving directory — last in that order — so
/// on the next play an embedded or beside-track file would win and silently
/// undo the choice. An entry here moves one file to the front of the lookup
/// order, for one track only, without touching any file the user owns.
///
/// Entries encode as `"<unix timestamp>\t<file path>"`. The timestamp is what
/// makes the table trimmable oldest-first; a bare path would leave no way to
/// choose which entry to drop once the table hits its ceiling.
public enum LyricsSelectionOverrideTable {
    /// Trimming kicks in above this many entries…
    public static let entryLimit = 300

    /// …and takes the table down to this many, so trimming is occasional
    /// rather than once per switch.
    public static let trimmedEntryCount = 200

    private static let fieldSeparator: Character = "\t"

    public static func filePath(forTrackId trackId: String, in table: [String: String]) -> String? {
        guard let entry = table[trackId] else {
            return nil
        }
        let path = decodeFilePath(from: entry)
        return path.isEmpty ? nil : path
    }

    public static func recording(
        filePath: String,
        forTrackId trackId: String,
        in table: [String: String],
        at date: Date
    ) -> [String: String] {
        var updatedTable = table
        updatedTable[trackId] = "\(date.timeIntervalSince1970)\(fieldSeparator)\(filePath)"
        guard updatedTable.count > entryLimit else {
            return updatedTable
        }
        // Sort by recency, breaking ties on the track id so trimming is
        // deterministic rather than dependent on dictionary ordering.
        let survivingTrackIds = Set(
            updatedTable
                .sorted { leftEntry, rightEntry in
                    let leftTimestamp = decodeTimestamp(from: leftEntry.value)
                    let rightTimestamp = decodeTimestamp(from: rightEntry.value)
                    if leftTimestamp == rightTimestamp {
                        return leftEntry.key < rightEntry.key
                    }
                    return leftTimestamp > rightTimestamp
                }
                .prefix(trimmedEntryCount)
                .map(\.key)
        )
        return updatedTable.filter { survivingTrackIds.contains($0.key) }
    }

    public static func removing(trackId: String, from table: [String: String]) -> [String: String] {
        var updatedTable = table
        updatedTable.removeValue(forKey: trackId)
        return updatedTable
    }

    private static func decodeTimestamp(from entry: String) -> TimeInterval {
        guard let separatorIndex = entry.firstIndex(of: fieldSeparator) else {
            return 0
        }
        return TimeInterval(entry[entry.startIndex ..< separatorIndex]) ?? 0
    }

    private static func decodeFilePath(from entry: String) -> String {
        guard let separatorIndex = entry.firstIndex(of: fieldSeparator) else {
            // An entry written before the timestamp existed, or a hand-edited
            // preference: treat the whole value as the path rather than
            // dropping a selection the user made.
            return entry
        }
        return String(entry[entry.index(after: separatorIndex)...])
    }
}
