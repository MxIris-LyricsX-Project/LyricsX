import CoreAudio
import Foundation
import OSToolbox

/// An audio device the system can play sound through, as Core Audio reports it.
public struct AudioOutputDevice: Hashable, Sendable {
    /// `kAudioDevicePropertyDeviceUID`: the same across restarts, unlike the
    /// device's ID, and the same after the user renames the device.
    public var uid: String

    /// The name Sound settings shows for the device.
    public var name: String

    /// `kAudioDevicePropertyTransportType`, such as
    /// `kAudioDeviceTransportTypeAirPlay` or `kAudioDeviceTransportTypeBluetooth`.
    public var transportType: UInt32

    public init(uid: String, name: String, transportType: UInt32) {
        self.uid = uid
        self.name = name
        self.transportType = transportType
    }

    /// The identifier shared by every AirPlay output.
    public static let airPlayPersistentIdentifier = "transport.airplay"

    /// What a setting for this device is kept under: one value each time the
    /// device comes back.
    ///
    /// That is the device's UID, except over AirPlay. An AirPlay receiver —
    /// a HomePod, a stereo pair, an Apple TV — appears as a device named just
    /// "AirPlay" whose UID is made anew for every connection: one HomePod pair
    /// left seven of them behind in Core Audio's settings, each
    /// `<UUID>-<number>-Audio` with a new number. Nothing in Core Audio names
    /// the receiver, so all AirPlay outputs share
    /// ``airPlayPersistentIdentifier``.
    public var persistentIdentifier: String {
        transportType == kAudioDeviceTransportTypeAirPlay ? Self.airPlayPersistentIdentifier : uid
    }

    /// The device the system plays sound through — the output picked in
    /// Sound settings or the menu bar's Sound menu — or `nil` when Core Audio
    /// does not report one.
    ///
    /// A player that picks its own device, such as Music streaming to AirPlay
    /// from its own menu, plays elsewhere; Core Audio has no way to tell.
    public static func systemDefault() -> AudioOutputDevice? {
        var address = AudioObjectPropertyAddress.systemDefaultOutputDevice
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return AudioOutputDevice(deviceID: deviceID)
    }

    /// Every device with an output stream.
    static func allOutputDevices() -> [AudioOutputDevice] {
        allOutputDeviceIDs().compactMap(AudioOutputDevice.init(deviceID:))
    }

    static func allOutputDeviceIDs() -> [AudioDeviceID] {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr else { return [] }
        var deviceIDs = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &deviceIDs) == noErr else { return [] }
        return deviceIDs.filter { outputStreamCount(of: $0) > 0 }
    }

    init?(deviceID: AudioDeviceID) {
        guard let uid = Self.stringProperty(kAudioDevicePropertyDeviceUID, of: deviceID), !uid.isEmpty else {
            return nil
        }
        self.uid = uid
        self.name = Self.stringProperty(kAudioObjectPropertyName, of: deviceID) ?? uid
        var transportType: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transportType) != noErr {
            transportType = 0
        }
        self.transportType = transportType
    }

    static func stringProperty(_ selector: AudioObjectPropertySelector, of objectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else { return nil }
        // Core Audio hands out string properties retained, for the caller to release.
        return value?.takeRetainedValue() as String?
    }

    static func outputStreamCount(of deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }
}

extension AudioObjectPropertyAddress {
    static var systemDefaultOutputDevice: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}

/// Reports the device the system plays sound through each time it changes.
///
/// The Core Audio listener stays installed for the observer's lifetime.
@Loggable(subsystem: "com.JH.LyricsX.diagnostics", category: "AudioOutputDeviceObserver")
public final class SystemDefaultAudioOutputDeviceObserver {
    private let queue: DispatchQueue

    private let listener: AudioObjectPropertyListenerBlock

    private let isListening: Bool

    /// Starts observing; `handler` runs on `queue` with the new device, or
    /// `nil` when Core Audio reports none.
    public init(queue: DispatchQueue, handler: @escaping @Sendable (AudioOutputDevice?) -> Void) {
        self.queue = queue
        listener = { _, _ in
            handler(AudioOutputDevice.systemDefault())
        }
        var address = AudioObjectPropertyAddress.systemDefaultOutputDevice
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        isListening = status == noErr
        if !isListening {
            #log(.error, "Could not observe the default output device: OSStatus \(status, privacy: .public)")
        }
    }

    deinit {
        guard isListening else { return }
        var address = AudioObjectPropertyAddress.systemDefaultOutputDevice
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
    }
}
