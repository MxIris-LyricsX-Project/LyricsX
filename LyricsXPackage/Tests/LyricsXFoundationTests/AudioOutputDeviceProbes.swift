import CoreAudio
import Foundation
import Testing
@testable import LyricsXFoundation

// The real Core Audio devices of the Mac the tests run on. A lyrics offset is
// kept per output device, so the device the system plays through has to be
// readable, and every device apart from AirPlay ones has to report a UID of
// its own. The listing is printed: a run while a HomePod is the output shows
// what Core Audio makes of it — on macOS 27.2, a device named "AirPlay" with
// a UID made for that connection, no data sources, and nothing that names
// the receiver.

@Suite("Core Audio output devices on this Mac")
struct AudioOutputDeviceProbes {
    @Test("the system's default output device can be read")
    func systemDefaultIsReadable() throws {
        let device = try #require(AudioOutputDevice.systemDefault())
        print("default output device: uid=\(device.uid) name=\(device.name) transport=\(fourCharacterCode(device.transportType)) persistentIdentifier=\(device.persistentIdentifier)")
        #expect(!device.uid.isEmpty)
        #expect(!device.name.isEmpty)
    }

    @Test("every output device other than AirPlay is kept under a UID of its own")
    func outputDevicesHaveDistinctIdentifiers() {
        for deviceID in AudioOutputDevice.allOutputDeviceIDs() {
            let device = AudioOutputDevice(deviceID: deviceID)
            print("output device \(deviceID): uid=\(device?.uid ?? "<none>") name=\(device?.name ?? "<none>") transport=\(fourCharacterCode(device?.transportType ?? 0)) dataSources=\(dataSourceDescriptions(of: deviceID))")
        }
        let devices = AudioOutputDevice.allOutputDevices()
        let otherDevices = devices.filter { $0.transportType != kAudioDeviceTransportTypeAirPlay }
        #expect(!devices.isEmpty)
        #expect(otherDevices.allSatisfy { $0.persistentIdentifier == $0.uid })
        #expect(Set(otherDevices.map(\.persistentIdentifier)).count == otherDevices.count)
    }
}

private func fourCharacterCode(_ value: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }
    return String(bytes: bytes, encoding: .macOSRoman) ?? String(value)
}

/// The output data sources a device offers, by name, with the current one
/// marked — how Core Audio would tell apart outputs that share one device.
private func dataSourceDescriptions(of deviceID: AudioDeviceID) -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDataSources,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else { return "[]" }
    var sourceIDs = [UInt32](repeating: 0, count: Int(size) / MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &sourceIDs) == noErr else { return "[]" }

    var currentSourceID: UInt32 = 0
    var currentAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDataSource,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    var currentSize = UInt32(MemoryLayout<UInt32>.size)
    _ = AudioObjectGetPropertyData(deviceID, &currentAddress, 0, nil, &currentSize, &currentSourceID)

    let names = sourceIDs.map { sourceID -> String in
        var sourceID = sourceID
        var name: Unmanaged<CFString>?
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSourceNameForIDCFString,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let label = withUnsafeMutablePointer(to: &sourceID) { sourcePointer in
            withUnsafeMutablePointer(to: &name) { namePointer -> String in
                var translation = AudioValueTranslation(
                    mInputData: sourcePointer,
                    mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                    mOutputData: namePointer,
                    mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                )
                var translationSize = UInt32(MemoryLayout<AudioValueTranslation>.size)
                guard AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &translationSize, &translation) == noErr else {
                    return fourCharacterCode(sourcePointer.pointee)
                }
                return namePointer.pointee?.takeRetainedValue() as String? ?? fourCharacterCode(sourcePointer.pointee)
            }
        }
        return sourceID == currentSourceID ? "*\(label)" : label
    }
    return "[" + names.joined(separator: ", ") + "]"
}
