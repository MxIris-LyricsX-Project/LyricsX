import AppKit
import Testing
@testable import LyricsXFoundation

@Test
func lyricsEditingAllowsCreatingABlankFile() {
    #expect(!LyricsEditingPolicy.canEdit(
        hasLyrics: false,
        hasLocalFile: false,
        canPersist: false,
        canCreateBlankFile: false
    ))
    #expect(LyricsEditingPolicy.canEdit(
        hasLyrics: false,
        hasLocalFile: false,
        canPersist: false,
        canCreateBlankFile: true
    ))
    #expect(!LyricsEditingPolicy.canEdit(
        hasLyrics: true,
        hasLocalFile: false,
        canPersist: false,
        canCreateBlankFile: true
    ))
    #expect(LyricsEditingPolicy.canEdit(
        hasLyrics: true,
        hasLocalFile: true,
        canPersist: false,
        canCreateBlankFile: false
    ))
    #expect(LyricsEditingPolicy.canEdit(
        hasLyrics: true,
        hasLocalFile: false,
        canPersist: true,
        canCreateBlankFile: false
    ))
}

@Test
func preparingABlankLyricsFileDoesNotOverwriteExistingContent() throws {
    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }

    let destination = LyricsStorageDestination(
        fileURL: directoryURL.appendingPathComponent("Track.lrcx"),
        securityScopedDirectoryURL: nil
    )
    let fileURL = try LyricsStoragePolicy.prepareEmptyFile(at: destination)
    #expect(try String(contentsOf: fileURL, encoding: .utf8).isEmpty)

    try "keep existing lyrics".write(to: fileURL, atomically: true, encoding: .utf8)
    _ = try LyricsStoragePolicy.prepareEmptyFile(at: destination)
    #expect(try String(contentsOf: fileURL, encoding: .utf8) == "keep existing lyrics")
}

@Test @MainActor
func lyricsTextViewHandlesInteractionsAtTheHitTestTarget() throws {
    let textView = LyricsInteractionTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 280))
    var doubleClickCount = 0
    textView.doubleClickHandler = { _ in
        doubleClickCount += 1
    }

    let doubleClickEvent = try #require(NSEvent.mouseEvent(
        with: .leftMouseUp,
        location: NSPoint(x: 160, y: 140),
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: 2,
        pressure: 0
    ))
    textView.mouseUp(with: doubleClickEvent)

    let expectedMenu = NSMenu()
    expectedMenu.addItem(withTitle: "Search", action: nil, keyEquivalent: "")
    textView.contextMenuProvider = { _ in expectedMenu }
    let rightClickEvent = try #require(NSEvent.mouseEvent(
        with: .rightMouseDown,
        location: NSPoint(x: 160, y: 140),
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 0
    ))

    #expect(doubleClickCount == 1)
    #expect(textView.menu(for: rightClickEvent) === expectedMenu)
}

@Test @MainActor
func noLyricsPlaceholderUsesTheSameContextMenuProvider() throws {
    let label = LyricsContextMenuTextField(labelWithString: "No Lyrics")
    let expectedMenu = NSMenu()
    expectedMenu.addItem(withTitle: "Search", action: nil, keyEquivalent: "")
    label.contextMenuProvider = { _ in expectedMenu }
    let rightClickEvent = try #require(NSEvent.mouseEvent(
        with: .rightMouseDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 0
    ))

    #expect(label.menu(for: rightClickEvent) === expectedMenu)
}

@Test
func lyricsStorageDefaultsToLRCX() throws {
    let destination = try #require(LyricsStoragePolicy.destination(
        locationRawValue: LyricsSavingLocation.lyricsXDirectory.rawValue,
        title: "Song/Title",
        artist: "Artist",
        defaultDirectoryURL: URL(fileURLWithPath: "/Music/LyricsX"),
        customDirectoryURL: nil
    ))

    #expect(destination.fileURL.path == "/Music/LyricsX/Song:Title - Artist.lrcx")
    #expect(destination.securityScopedDirectoryURL == nil)
}

@Test
func lyricsStoragePreservesLegacyCustomDirectoryIndex() throws {
    let customDirectory = URL(fileURLWithPath: "/Custom/Lyrics")
    let destination = try #require(LyricsStoragePolicy.destination(
        locationRawValue: 1,
        title: "Song",
        artist: "Artist",
        defaultDirectoryURL: URL(fileURLWithPath: "/Music/LyricsX"),
        customDirectoryURL: customDirectory
    ))

    #expect(destination.fileURL.path == "/Custom/Lyrics/Song - Artist.lrcx")
    #expect(destination.securityScopedDirectoryURL == customDirectory)
}

@Test
func lyricsStorageReadsCanonicalNamesBeforeLegacyUntrimmedNames() {
    let candidates = LyricsStoragePolicy.libraryFileBaseNameCandidates(
        title: " Song ",
        artist: "Artist"
    )

    #expect(candidates == ["Song - Artist", " Song  - Artist"])
}

@Test
func lyricsStorageRecognizesFilesInsideASecurityScopedDirectory() throws {
    let directory = URL(fileURLWithPath: "/Music/Custom Lyrics")
    #expect(LyricsStoragePolicy.contains(
        directory.appendingPathComponent("Album/Track.lrcx"),
        in: directory
    ))
    #expect(!LyricsStoragePolicy.contains(
        URL(fileURLWithPath: "/Music/Custom Lyrics 2/Track.lrcx"),
        in: directory
    ))
    #expect(!LyricsStoragePolicy.contains(directory, in: directory))
}

@Test
func lyricsStorageKeepsUserBesideTrackFilesReadOnlyByDefault() throws {
    let library = URL(fileURLWithPath: "/Music/LyricsX")
    let custom = URL(fileURLWithPath: "/Custom/Lyrics")
    let besideTrack = URL(fileURLWithPath: "/Music/Album/Track.lrcx")
    let managedCustom = custom.appendingPathComponent("Song - Artist.lrcx")
    let managedDefault = library.appendingPathComponent("Song - Artist.lrcx")
    let libraryDestination = try #require(LyricsStoragePolicy.destination(
        locationRawValue: 0,
        title: "Song",
        artist: "Artist",
        defaultDirectoryURL: library,
        customDirectoryURL: custom
    ))

    #expect(LyricsStoragePolicy.isManagedLibraryFile(
        managedDefault,
        defaultDirectoryURL: library,
        customDirectoryURL: custom
    ))
    #expect(LyricsStoragePolicy.isManagedLibraryFile(
        managedCustom,
        defaultDirectoryURL: library,
        customDirectoryURL: custom
    ))
    #expect(!LyricsStoragePolicy.isManagedLibraryFile(
        besideTrack,
        defaultDirectoryURL: library,
        customDirectoryURL: custom
    ))

    let defaultPersist = try #require(LyricsStoragePolicy.persistDestination(
        localURL: besideTrack,
        allowUnmanagedLocalWriteBack: false,
        defaultDirectoryURL: library,
        customDirectoryURL: custom,
        libraryDestination: libraryDestination
    ))
    #expect(defaultPersist == libraryDestination)

    let allowedPersist = try #require(LyricsStoragePolicy.persistDestination(
        localURL: besideTrack,
        allowUnmanagedLocalWriteBack: true,
        defaultDirectoryURL: library,
        customDirectoryURL: custom,
        libraryDestination: libraryDestination
    ))
    #expect(allowedPersist.fileURL == besideTrack)

    let managedPersist = try #require(LyricsStoragePolicy.persistDestination(
        localURL: managedCustom,
        allowUnmanagedLocalWriteBack: false,
        defaultDirectoryURL: library,
        customDirectoryURL: custom,
        libraryDestination: libraryDestination
    ))
    #expect(managedPersist.fileURL == managedCustom)
    #expect(managedPersist.securityScopedDirectoryURL == custom)
}

@Test
func aiLyricsTranslationRequestUsesBoundedJSONMode() throws {
    let configuration = AILyricsTranslationConfiguration(
        endpoint: try #require(URL(string: "https://example.com/v1/chat/completions")),
        model: "test-model",
        targetLanguage: "zh-Hans",
        prompt: "Translate to $targetLanguage"
    )
    let request = try OpenAICompatibleChatRequest(
        configuration: configuration,
        sourceLanguage: "en",
        sourceLines: [AILyricsTranslationInputLine(index: 3, text: "A lyric")]
    )
    let data = try JSONEncoder().encode(request)
    let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let responseFormat = try #require(payload["response_format"] as? [String: String])

    #expect(payload["max_tokens"] as? Int == 4_096)
    #expect(responseFormat["type"] == "json_object")
    #expect(payload["model"] as? String == "test-model")
}

@Test
func aiLyricsTranslationBatchesRespectLineAndByteLimits() throws {
    let lines = (0 ..< 25).map {
        AILyricsTranslationInputLine(index: $0, text: "Line \($0)")
    }
    let lineLimitedBatches = try AILyricsTranslationBatchPolicy.batches(lines)

    #expect(lineLimitedBatches.map(\.count) == [24, 1])
    #expect(lineLimitedBatches.allSatisfy { $0.count <= AILyricsTranslationBatchPolicy.maximumLines })

    let byteLimitedLines = (0 ..< 24).map {
        AILyricsTranslationInputLine(index: $0, text: String(repeating: "x", count: 2_000))
    }
    let byteLimitedBatches = try AILyricsTranslationBatchPolicy.batches(byteLimitedLines)

    #expect(byteLimitedBatches.count > 1)
    for batch in byteLimitedBatches {
        #expect(try JSONEncoder().encode(batch).count <= AILyricsTranslationBatchPolicy.maximumSourceBytes)
    }
}

@Test
func aiLyricsTranslationKeepsValidPartialResponseEntries() throws {
    let response = """
    {"translations":[{"index":4,"text":"bonjour"},{"index":6,"text":"hola"},{"index":7,"text":""}]}
    """
    let parsed = try AILyricsTranslationPolicy.parsedTranslations(
        response: response,
        expectedIndices: [4, 5, 6, 7]
    )

    #expect(parsed.translations == [4: "bonjour", 6: "hola"])
    #expect(parsed.missingIndices == [5, 7])
}

@Test
func aiLyricsTranslationDiscardsAmbiguousDuplicateIndices() throws {
    let response = """
    {"translations":[{"index":2,"text":"first"},{"index":2,"text":"second"},{"index":3,"text":"valid"}]}
    """
    let parsed = try AILyricsTranslationPolicy.parsedTranslations(
        response: response,
        expectedIndices: [2, 3]
    )

    #expect(parsed.translations == [3: "valid"])
    #expect(parsed.missingIndices == [2])
}

@Test
func aiLyricsTranslationRecognizesBareAndLanguageQualifiedTranslationTags() {
    let bareTagCandidates = AILyricsTranslationPolicy.translationLanguageCandidates(
        attachmentTagRawValues: ["tr"],
        targetLanguage: "zh-Hans"
    )
    let qualifiedTagCandidates = AILyricsTranslationPolicy.translationLanguageCandidates(
        attachmentTagRawValues: ["tr:zh-Hans", "tr:ja"],
        targetLanguage: "zh-Hans"
    )

    #expect(bareTagCandidates.count == 2)
    #expect(bareTagCandidates[0] == "zh-Hans")
    #expect(bareTagCandidates[1] == nil)
    #expect(qualifiedTagCandidates == ["zh-Hans"])
}
