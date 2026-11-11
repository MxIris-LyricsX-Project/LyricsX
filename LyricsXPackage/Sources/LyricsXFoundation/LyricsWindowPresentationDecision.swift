public enum LyricsWindowPresentationAction: Equatable, Sendable {
    case show
    case bringToFront
    case close
}

public enum LyricsWindowPresentationDecision {
    public static func action(
        isWindowVisible: Bool,
        isApplicationActive: Bool
    ) -> LyricsWindowPresentationAction {
        guard isWindowVisible else { return .show }
        return isApplicationActive ? .close : .bringToFront
    }
}
