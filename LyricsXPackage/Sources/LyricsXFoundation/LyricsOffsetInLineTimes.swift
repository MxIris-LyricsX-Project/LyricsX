import Foundation
import LyricsKit

extension Lyrics {
    /// A copy for writing to a source other players read, many of which ignore
    /// an `[offset:]` tag: the offset is moved into every line time and the tag
    /// is left out. Word timings count from their line's start, so they move
    /// with it. A line the offset would put before the start of the track is
    /// put at zero.
    ///
    /// The lyrics on screen keep their own times, which the panel and saved
    /// translations use to recognise a line, so only what is written changes.
    public var withOffsetInLineTimes: Lyrics {
        let shift = TimeInterval(offset) / 1000
        var idTags = idTags
        idTags[.offset] = nil
        let lines = lines.map { line -> LyricsLine in
            var line = line
            line.position = max(0, line.position - shift)
            return line
        }
        return Lyrics(lines: lines, idTags: idTags, metadata: metadata)
    }
}
