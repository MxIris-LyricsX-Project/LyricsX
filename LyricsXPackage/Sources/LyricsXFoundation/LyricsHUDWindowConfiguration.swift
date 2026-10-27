import AppKit

public enum LyricsHUDWindowConfiguration {
    public static let collectionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces,
        .fullScreenAuxiliary,
    ]

    @MainActor
    public static func apply(to window: NSWindow) {
        window.collectionBehavior = collectionBehavior
    }

    /// The font the lyrics window draws its lyrics in: the one chosen in
    /// Display preferences, or the system font at the same size once that
    /// one can no longer be loaded — removed in Font Book, or deactivated by
    /// a font manager while its name stays in the preferences.
    public static func textFont(named fontName: String, size: CGFloat) -> NSFont {
        NSFont(name: fontName, size: size) ?? .labelFont(ofSize: size)
    }
}
