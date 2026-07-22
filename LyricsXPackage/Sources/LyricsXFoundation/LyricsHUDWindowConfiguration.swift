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
}
