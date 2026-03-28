import Foundation

public struct WidgetDataStore: Sendable {
    public static let dataKey = "widgetLyricsData"
    public static let coverFileName = "cover.jpg"

    private let groupIdentifier: String

    public init(groupIdentifier: String) {
        self.groupIdentifier = groupIdentifier
    }

    private var groupDefaults: UserDefaults? {
        UserDefaults(suiteName: groupIdentifier)
    }

    private var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)
    }

    // MARK: - LyricsWidgetData

    public func write(_ data: LyricsWidgetData) throws {
        let encoded = try JSONEncoder().encode(data)
        groupDefaults?.set(encoded, forKey: Self.dataKey)
    }

    public func read() -> LyricsWidgetData? {
        guard let data = groupDefaults?.data(forKey: Self.dataKey) else { return nil }
        return try? JSONDecoder().decode(LyricsWidgetData.self, from: data)
    }

    public func clear() {
        groupDefaults?.removeObject(forKey: Self.dataKey)
        clearCover()
    }

    // MARK: - Album Cover

    public var coverURL: URL? {
        sharedContainerURL?.appendingPathComponent(Self.coverFileName)
    }

    public func writeCover(_ jpegData: Data) throws {
        guard let coverURL else { return }
        try jpegData.write(to: coverURL, options: .atomic)
    }

    public func clearCover() {
        guard let coverURL else { return }
        try? FileManager.default.removeItem(at: coverURL)
    }
}
