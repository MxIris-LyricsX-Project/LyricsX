import Foundation

/// How a track reaches the listener: the app that plays it and the audio
/// device the system plays that app's sound through.
///
/// Players compensate for the output's latency in their own ways — QQ Music
/// takes a fixed 2.205 s off its progress whenever the output is AirPlay,
/// NetEase Cloud Music takes nothing off — so the lyrics need a correction
/// of their own for each pair, not one for each device.
public struct PlaybackRoute: Hashable, Codable, Sendable {
    /// The bundle identifier of the app the track plays in.
    public var playerBundleIdentifier: String

    /// The output device's ``AudioOutputDevice/persistentIdentifier``: its
    /// UID, which stays the same across restarts while its name can change,
    /// or one identifier for every AirPlay output.
    public var outputDeviceIdentifier: String

    public init(playerBundleIdentifier: String, outputDeviceIdentifier: String) {
        self.playerBundleIdentifier = playerBundleIdentifier
        self.outputDeviceIdentifier = outputDeviceIdentifier
    }
}

/// The lyrics offsets set for particular playback routes.
///
/// A route's offset adds to each lyrics' own offset and to the global one,
/// in the same unit and direction: milliseconds, a positive offset showing
/// the lyrics earlier. A route nobody set an offset for adds nothing.
public struct PlaybackRouteLyricsOffsets: Equatable, Sendable {
    public struct Entry: Hashable, Codable, Sendable, Identifiable {
        public var route: PlaybackRoute

        /// The player's name when the offset was last set, shown while the
        /// app cannot be found.
        public var playerName: String

        /// The output device's name when the offset was last set, shown
        /// while the device is not connected.
        public var outputDeviceName: String

        /// Milliseconds; a positive offset shows the lyrics earlier.
        public var offset: Int

        public var id: PlaybackRoute {
            route
        }

        public init(route: PlaybackRoute, playerName: String, outputDeviceName: String, offset: Int) {
            self.route = route
            self.playerName = playerName
            self.outputDeviceName = outputDeviceName
            self.offset = offset
        }
    }

    /// The routes with an offset, in the order they were first set.
    public private(set) var entries: [Entry]

    public init(entries: [Entry] = []) {
        var seenRoutes = Set<PlaybackRoute>()
        self.entries = entries.filter { $0.offset != 0 && seenRoutes.insert($0.route).inserted }
    }

    /// The offset set for `route`, or 0 when there is none or no route.
    public func offset(for route: PlaybackRoute?) -> Int {
        guard let route else { return 0 }
        return entries.first { $0.route == route }?.offset ?? 0
    }

    /// Sets the offset for `route`, keeping the names to show for it later.
    ///
    /// A route that already has an offset keeps its place in ``entries``.
    /// Setting an offset of 0 removes the route's entry: it adds nothing,
    /// and the list keeps only the routes that do.
    public mutating func setOffset(_ offset: Int, for route: PlaybackRoute, playerName: String, outputDeviceName: String) {
        guard offset != 0 else {
            removeOffset(for: route)
            return
        }
        let entry = Entry(route: route, playerName: playerName, outputDeviceName: outputDeviceName, offset: offset)
        if let index = entries.firstIndex(where: { $0.route == route }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }

    /// Removes the offset set for `route`, if there is one.
    public mutating func removeOffset(for route: PlaybackRoute) {
        entries.removeAll { $0.route == route }
    }
}

extension PlaybackRouteLyricsOffsets: Codable {
    public init(from decoder: Decoder) throws {
        try self.init(entries: decoder.singleValueContainer().decode([Entry].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(entries)
    }
}

extension PlaybackRouteLyricsOffsets {
    /// The offsets stored as `storedData`. Data that does not decode — absent,
    /// or written by something else — reads as no offsets at all.
    public init(storedData: Data?) {
        guard let storedData, let offsets = try? JSONDecoder().decode(Self.self, from: storedData) else {
            self.init()
            return
        }
        self = offsets
    }

    /// The offsets as data to store in the user defaults.
    public var storedData: Data {
        // Encoding plain strings and integers cannot fail.
        (try? JSONEncoder().encode(self)) ?? Data("[]".utf8)
    }
}
