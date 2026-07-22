public enum LyricsEditingPolicy {
    public static func canEdit(
        hasLyrics: Bool,
        hasLocalFile: Bool,
        canPersist: Bool,
        canCreateBlankFile: Bool
    ) -> Bool {
        if hasLyrics {
            return hasLocalFile || canPersist
        }
        return canCreateBlankFile
    }
}
