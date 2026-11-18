import Foundation
import Testing
@testable import LyricsXFoundation

// A lyrics offset per player and output device. QQ Music takes a fixed 2.205 s
// off its progress whenever the output is AirPlay; NetEase Cloud Music takes
// nothing off. On a HomePod mini 2, whose real latency is close to zero, the
// two need different corrections on the same device, so the offsets are kept
// per pair and never shared between pairs. Every AirPlay output is one device
// here: Core Audio gives an AirPlay receiver a new UID for every connection.

private let qqMusic = "com.tencent.QQMusic.D5Q73692VW"
private let netEaseCloudMusic = "com.netease.163music"
private let airPlay = AudioOutputDevice.airPlayPersistentIdentifier
private let builtInSpeakers = "BuiltInSpeakerDevice"

private let qqMusicOnAirPlay = PlaybackRoute(playerBundleIdentifier: qqMusic, outputDeviceIdentifier: airPlay)
private let qqMusicOnSpeakers = PlaybackRoute(playerBundleIdentifier: qqMusic, outputDeviceIdentifier: builtInSpeakers)
private let netEaseOnAirPlay = PlaybackRoute(playerBundleIdentifier: netEaseCloudMusic, outputDeviceIdentifier: airPlay)

@Suite("Lyrics offsets per player and output device")
struct PlaybackRouteLyricsOffsetsTests {
    @Test("a route nobody set an offset for adds nothing")
    func unsetRouteAddsNothing() {
        let offsets = PlaybackRouteLyricsOffsets()
        #expect(offsets.offset(for: qqMusicOnAirPlay) == 0)
        #expect(offsets.offset(for: nil) == 0)
    }

    @Test("an offset applies to its own player and device only")
    func offsetIsPerPair() {
        var offsets = PlaybackRouteLyricsOffsets()
        offsets.setOffset(2205, for: qqMusicOnAirPlay, playerName: "QQ音乐", outputDeviceName: "AirPlay")
        #expect(offsets.offset(for: qqMusicOnAirPlay) == 2205)
        #expect(offsets.offset(for: qqMusicOnSpeakers) == 0)
        #expect(offsets.offset(for: netEaseOnAirPlay) == 0)
    }

    @Test("setting a route again replaces its offset and names in place")
    func settingAgainReplacesInPlace() {
        var offsets = PlaybackRouteLyricsOffsets()
        offsets.setOffset(2205, for: qqMusicOnAirPlay, playerName: "QQ音乐", outputDeviceName: "AirPlay")
        offsets.setOffset(-300, for: netEaseOnAirPlay, playerName: "网易云音乐", outputDeviceName: "AirPlay")
        offsets.setOffset(2100, for: qqMusicOnAirPlay, playerName: "QQ音乐", outputDeviceName: "隔空播放")

        #expect(offsets.entries.map(\.route) == [qqMusicOnAirPlay, netEaseOnAirPlay])
        #expect(offsets.entries.first?.offset == 2100)
        #expect(offsets.entries.first?.outputDeviceName == "隔空播放")
    }

    @Test("setting an offset of 0 removes the route's entry")
    func zeroRemovesTheEntry() {
        var offsets = PlaybackRouteLyricsOffsets()
        offsets.setOffset(2205, for: qqMusicOnAirPlay, playerName: "QQ音乐", outputDeviceName: "AirPlay")
        offsets.setOffset(0, for: qqMusicOnAirPlay, playerName: "QQ音乐", outputDeviceName: "AirPlay")
        #expect(offsets.entries.isEmpty)

        offsets.setOffset(0, for: netEaseOnAirPlay, playerName: "网易云音乐", outputDeviceName: "AirPlay")
        #expect(offsets.entries.isEmpty)
    }

    @Test("removing a route leaves the others alone")
    func removingLeavesOthers() {
        var offsets = PlaybackRouteLyricsOffsets()
        offsets.setOffset(2205, for: qqMusicOnAirPlay, playerName: "QQ音乐", outputDeviceName: "AirPlay")
        offsets.setOffset(100, for: qqMusicOnSpeakers, playerName: "QQ音乐", outputDeviceName: "MacBook Pro 扬声器")
        offsets.removeOffset(for: qqMusicOnAirPlay)
        #expect(offsets.entries.map(\.route) == [qqMusicOnSpeakers])
        offsets.removeOffset(for: netEaseOnAirPlay)
        #expect(offsets.entries.map(\.route) == [qqMusicOnSpeakers])
    }

    @Test("the stored offsets come back as they were saved")
    func storedDataRoundTrips() {
        var offsets = PlaybackRouteLyricsOffsets()
        offsets.setOffset(2205, for: qqMusicOnAirPlay, playerName: "QQ音乐", outputDeviceName: "AirPlay")
        offsets.setOffset(-150, for: netEaseOnAirPlay, playerName: "网易云音乐", outputDeviceName: "AirPlay")
        #expect(PlaybackRouteLyricsOffsets(storedData: offsets.storedData) == offsets)
    }

    // The stored form outlives any one build: renaming a property would
    // silently drop every offset a user has set.
    @Test("offsets stored by an earlier build still read")
    func storedFormIsStable() {
        let storedData = Data("""
        [{"route":{"playerBundleIdentifier":"com.tencent.QQMusic.D5Q73692VW","outputDeviceIdentifier":"transport.airplay"},\
        "playerName":"QQ音乐","outputDeviceName":"AirPlay","offset":2205}]
        """.utf8)
        let offsets = PlaybackRouteLyricsOffsets(storedData: storedData)
        #expect(offsets.offset(for: qqMusicOnAirPlay) == 2205)
        #expect(offsets.entries.first?.playerName == "QQ音乐")
    }

    @Test("stored data that does not decode reads as no offsets", arguments: [
        nil,
        Data(),
        Data("not json".utf8),
        Data(#"{"offset":2205}"#.utf8),
    ])
    func undecodableDataReadsAsEmpty(storedData: Data?) {
        #expect(PlaybackRouteLyricsOffsets(storedData: storedData).entries.isEmpty)
    }

    @Test("stored entries that repeat a route or add nothing are dropped")
    func storedDuplicatesAndZerosAreDropped() {
        let offsets = PlaybackRouteLyricsOffsets(entries: [
            .init(route: qqMusicOnAirPlay, playerName: "QQ音乐", outputDeviceName: "AirPlay", offset: 2205),
            .init(route: qqMusicOnAirPlay, playerName: "QQ音乐", outputDeviceName: "AirPlay", offset: 999),
            .init(route: netEaseOnAirPlay, playerName: "网易云音乐", outputDeviceName: "AirPlay", offset: 0),
        ])
        #expect(offsets.entries.map(\.route) == [qqMusicOnAirPlay])
        #expect(offsets.offset(for: qqMusicOnAirPlay) == 2205)
    }
}
