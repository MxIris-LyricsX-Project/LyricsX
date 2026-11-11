import Foundation
import LyricsXFoundation
import Testing

struct StructuredTimingIntegrationTests {
    @Test func appleMusicTimedTextSurvivesParsingAndLyricsSerialization() throws {
        let timedTextMarkupLanguageContent =
            "<tt xmlns=\"http://www.w3.org/ns/ttml\" xml:lang=\"en-US\"><body><div>" +
            "<p begin=\"20.000\" end=\"22.000\"><span begin=\"20.000\" end=\"22.000\">" +
            "<span begin=\"20.000\" end=\"20.500\">Hel</span>" +
            "<span begin=\"20.500\" end=\"22.000\">lo</span>" +
            "</span></p></div></body></tt>"

        let parsedLyrics = try #require(Lyrics(ttmlContent: timedTextMarkupLanguageContent))
        let parsedTiming = try #require(parsedLyrics.lines.first?.attachments.synchronizedTextTiming)
        #expect(parsedTiming.words.count == 1)
        #expect(parsedTiming.words[0].syllables.count == 2)
        #expect(parsedTiming.words[0].timeRange == 0 ..< 2)

        let reparsedLyrics = try #require(Lyrics(parsedLyrics.description))
        #expect(reparsedLyrics.lines[0].attachments.synchronizedTextTiming == parsedTiming)
        #expect(reparsedLyrics.lines[0].attachments.timetag?.tags.first?.index == 0)
    }

    @Test func timedTextCharacterRangesUseSwiftCharacterSemantics() throws {
        let timedTextMarkupLanguageContent =
            "<tt xmlns=\"http://www.w3.org/ns/ttml\" xml:lang=\"und\"><body><div>" +
            "<p begin=\"0.000\" end=\"3.000\">" +
            "<span begin=\"0.000\" end=\"1.000\">👨‍👩‍👧‍👦</span>" +
            "<span begin=\"1.000\" end=\"2.000\">é</span>" +
            "<span begin=\"2.000\" end=\"3.000\">中</span>" +
            "</p></div></body></tt>"

        let lyrics = try #require(Lyrics(ttmlContent: timedTextMarkupLanguageContent))
        let line = try #require(lyrics.lines.first)
        let timing = try #require(line.attachments.synchronizedTextTiming)
        #expect(line.content.count == 3)
        #expect(timing.words.map(\.characterRange) == [0 ..< 1, 1 ..< 2, 2 ..< 3])
    }

    @Test func flatTimedSpansKeepTheirExplicitEndsAndCompatibilityStarts() throws {
        let timedTextMarkupLanguageContent =
            "<tt xmlns=\"http://www.w3.org/ns/ttml\" xml:lang=\"zh-Hant\"><body><div>" +
            "<p begin=\"29.188\" end=\"32.398\">" +
            "<span begin=\"29.188\" end=\"30.449\">故事的</span>" +
            "<span begin=\"30.449\" end=\"32.398\">小黃花</span>" +
            "</p></div></body></tt>"

        let lyrics = try #require(Lyrics(ttmlContent: timedTextMarkupLanguageContent))
        let line = try #require(lyrics.lines.first)
        let timing = try #require(line.attachments.synchronizedTextTiming)
        #expect(timing.words.map(\.characterRange) == [0 ..< 3, 3 ..< 6])
        #expect(abs(timing.words[0].timeRange.upperBound - 1.261) < 0.000_001)
        #expect(timing.words[0].syllables.map(\.characterRange) == [0 ..< 3])
        #expect(line.attachments.timetag?.tags.map(\.index) == [0, 3])
    }

    @Test func reversedSerializedRangesAreRejectedWithoutCrashingTheLyricsParser() throws {
        let malformedPayload = """
        {
          "durationMilliseconds": 1000,
          "words": [{
            "endingCharacterIndex": 1,
            "endingTimeMilliseconds": 1000,
            "startingCharacterIndex": 5,
            "startingTimeMilliseconds": 0,
            "syllables": []
          }]
        }
        """
        let encodedPayload = Data(malformedPayload.utf8).base64EncodedString()
        let serializedLyrics = """
        [00:12.000]Hello
        [00:12.000][tt]<0,0><1000>
        [00:12.000][synchronized-timing]1:\(encodedPayload)
        """

        let lyrics = try #require(Lyrics(serializedLyrics))
        #expect(lyrics.lines[0].attachments.synchronizedTextTiming == nil)
        #expect(lyrics.lines[0].attachments.timetag != nil)
    }

    @Test func spansWithoutExplicitEndsRetainTheCompatibilityTiming() throws {
        let timedTextMarkupLanguageContent =
            "<tt xmlns=\"http://www.w3.org/ns/ttml\" xml:lang=\"en\"><body><div>" +
            "<p begin=\"10.000\" end=\"12.000\">" +
            "<span begin=\"10.000\">Hi</span>" +
            "<span begin=\"11.000\">there</span>" +
            "</p></div></body></tt>"

        let lyrics = try #require(Lyrics(ttmlContent: timedTextMarkupLanguageContent))
        let line = try #require(lyrics.lines.first)
        #expect(line.attachments.synchronizedTextTiming == nil)
        #expect(line.attachments.timetag?.tags.map(\.index) == [0, 2])
        #expect(line.attachments.timetag?.tags.map(\.time) == [0, 1])
    }
}
