import CoreAudio
import Testing
@testable import LyricsXFoundation

// A lyrics offset is kept under the output device's persistent identifier,
// which has to come out the same each time the device comes back. Core Audio
// gives an AirPlay receiver a new UID for every connection — the UIDs below
// are two connections to the same HomePod pair, from Core Audio's own
// settings — so keyed by UID, an offset set for AirPlay was lost the next
// time the HomePod was picked.

@Suite("What an output device's settings are kept under")
struct AudioOutputDeviceTests {
    @Test("every connection to an AirPlay receiver has the same identifier")
    func airPlayConnectionsShareIdentifier() {
        let firstConnection = AudioOutputDevice(
            uid: "7534dad1-c133-456f-8c49-2139a77aa23e-1042716128363833-Audio",
            name: "AirPlay",
            transportType: kAudioDeviceTransportTypeAirPlay
        )
        let nextConnection = AudioOutputDevice(
            uid: "7534dad1-c133-456f-8c49-2139a77aa23e-1050365501503375-Audio",
            name: "AirPlay",
            transportType: kAudioDeviceTransportTypeAirPlay
        )
        #expect(firstConnection.persistentIdentifier == nextConnection.persistentIdentifier)
        #expect(firstConnection.persistentIdentifier == AudioOutputDevice.airPlayPersistentIdentifier)
    }

    @Test("any other device is kept under its UID", arguments: [
        (uid: "BuiltInSpeakerDevice", transportType: kAudioDeviceTransportTypeBuiltIn),
        (uid: "AppleUSBAudioEngine:Apple Inc.:Studio Display:00008030-001574443EA3802E:8,9", transportType: kAudioDeviceTransportTypeUSB),
        (uid: "AC-80-0A-00-00-01:output", transportType: kAudioDeviceTransportTypeBluetooth),
    ])
    func otherDevicesUseUID(uid: String, transportType: UInt32) {
        let device = AudioOutputDevice(uid: uid, name: "Speakers", transportType: transportType)
        #expect(device.persistentIdentifier == uid)
    }
}
