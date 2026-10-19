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
func aiLyricsTranslationDropsALineTooLargeToBatchOnItsOwn() throws {
    // A whole verse pasted into one timestamp. It cannot fit in any batch, so
    // it is dropped here and counted as a failed line by the caller — it must
    // not take the rest of the track's translation down with it.
    let oversized = AILyricsTranslationInputLine(
        index: 1,
        text: String(repeating: "x", count: AILyricsTranslationBatchPolicy.maximumSourceBytes + 1)
    )
    let lines = [
        AILyricsTranslationInputLine(index: 0, text: "first"),
        oversized,
        AILyricsTranslationInputLine(index: 2, text: "third"),
    ]

    let batches = try AILyricsTranslationBatchPolicy.batches(lines)

    #expect(batches.flatMap { $0.map(\.index) } == [0, 2])
}

@Test
func aiLyricsTranslationRequestHonoursACustomTokenCap() throws {
    let configuration = AILyricsTranslationConfiguration(
        endpoint: try #require(URL(string: "https://example.com/v1/chat/completions")),
        model: "test-model",
        targetLanguage: "zh-Hans",
        prompt: "Translate to $targetLanguage"
    )
    let request = try OpenAICompatibleChatRequest(
        configuration: configuration,
        sourceLanguage: nil,
        sourceLines: [AILyricsTranslationInputLine(index: 0, text: "OK")],
        maxTokens: 32
    )

    let payload = try #require(
        JSONSerialization.jsonObject(with: try JSONEncoder().encode(request)) as? [String: Any]
    )

    #expect(payload["max_tokens"] as? Int == 32)
    #expect((payload["messages"] as? [[String: String]])?.count == 2)
}

@Test
func aiLyricsTranslationRequestUsesMaxCompletionTokensForOpenAI() throws {
    // OpenAI's reasoning models answer `max_tokens` with a 400 and take only
    // `max_completion_tokens`, which every OpenAI chat model accepts. Other
    // OpenAI-compatible servers mostly know only `max_tokens`.
    func payload(endpoint: String) throws -> [String: Any] {
        let configuration = AILyricsTranslationConfiguration(
            endpoint: try #require(URL(string: endpoint)),
            model: "test-model",
            targetLanguage: "ja",
            prompt: ""
        )
        let request = try OpenAICompatibleChatRequest(
            configuration: configuration,
            sourceLanguage: nil,
            sourceLines: [AILyricsTranslationInputLine(index: 0, text: "A lyric")],
            maxTokens: 64
        )
        return try #require(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(request)) as? [String: Any]
        )
    }

    let openAIPayload = try payload(endpoint: "https://api.openai.com/v1/chat/completions")
    #expect(openAIPayload["max_completion_tokens"] as? Int == 64)
    #expect(openAIPayload["max_tokens"] == nil)

    let compatiblePayload = try payload(endpoint: "https://api.deepseek.com/chat/completions")
    #expect(compatiblePayload["max_tokens"] as? Int == 64)
    #expect(compatiblePayload["max_completion_tokens"] == nil)
}

@Test
func aiLyricsTranslationAppliesOntoTheCurrentLyricsAndKeepsTheirOtherState() throws {
    // Stands in for the lyrics on screen when an answer lands: the user nudged
    // the offset and switched a line off while the request was in flight, and
    // both have to survive the merge.
    let source = try #require(Lyrics("[offset:1500]\n[00:01.000]first\n[00:02.000]second"))
    source.lines[1].enabled = false

    let translated = try AILyricsTranslationPolicy.applying([0: "erste"], to: source, targetLanguage: "de")

    #expect(translated.offset == 1500)
    #expect(translated.lines[1].enabled == false)
    #expect(translated.lines[0].attachments.translation(languageCodeCandidate: ["de"]) == "erste")
    #expect(translated.lines[1].attachments.translation(languageCodeCandidate: ["de"]) == nil)
    #expect(translated.metadata.attachmentTags.contains(.translation(languageCode: "de")))
    #expect(source.lines[0].attachments.translation(languageCodeCandidate: ["de"]) == nil)
}

@Test
func aiLyricsTranslationTreatsASupersededDefaultPromptAsUnset() {
    // The settings sheet used to write its pre-filled field back verbatim, so
    // an install that saved once holds the old default looking exactly like a
    // prompt the user wrote. Left alone, a rewritten default reaches nobody.
    let superseded = "Translate every lyric line into natural, concise $targetLanguage. Preserve the song's tone, imagery, names, and repeated phrases. Do not add explanations or commentary."
    let custom = "Translate into $targetLanguage and keep it terse."

    #expect(AILyricsTranslationPolicy.resolvedPrompt("") == AILyricsTranslationPolicy.defaultPrompt)
    #expect(AILyricsTranslationPolicy.resolvedPrompt("   ") == AILyricsTranslationPolicy.defaultPrompt)
    #expect(AILyricsTranslationPolicy.resolvedPrompt(superseded) == AILyricsTranslationPolicy.defaultPrompt)
    #expect(AILyricsTranslationPolicy.resolvedPrompt(custom) == custom)
}

@Test
func aiLyricsTranslationCompletesABaseEndpoint() throws {
    // Providers document a base_url, and copying it out of the docs is the
    // obvious thing to do. Both of these look like a finished endpoint and
    // both answer a request with a 404 that says nothing about the path it
    // wanted, so the path is appended for them.
    func endpoint(_ string: String) throws -> String {
        try AILyricsTranslationPolicy.validatedEndpoint(string).absoluteString
    }

    #expect(try endpoint("https://api.deepseek.com") == "https://api.deepseek.com/chat/completions")
    #expect(try endpoint("https://api.deepseek.com/") == "https://api.deepseek.com/chat/completions")
    #expect(try endpoint("https://api.deepseek.com/v1") == "https://api.deepseek.com/v1/chat/completions")
    #expect(try endpoint("http://localhost:8080") == "http://localhost:8080/chat/completions")

    // A path of its own is left exactly as given: a proxy or a provider that
    // answers somewhere else is not ours to correct.
    #expect(try endpoint("https://api.deepseek.com/chat/completions") == "https://api.deepseek.com/chat/completions")
    #expect(try endpoint("https://proxy.example.com/openai/v1/chat/completions") == "https://proxy.example.com/openai/v1/chat/completions")
}

@Test
func aiLyricsTranslationNeverCarriesABlankPrompt() throws {
    // An empty prompt still builds a well-formed request — one whose
    // instruction block is blank — so nothing downstream fails; it just
    // translates nothing. The default is substituted where that block is
    // built, and the configuration keeps reporting what it was given.
    let configuration = AILyricsTranslationConfiguration(
        endpoint: try #require(URL(string: "https://example.com/v1/chat/completions")),
        model: "test-model",
        targetLanguage: "ja",
        prompt: "   "
    )
    let request = try OpenAICompatibleChatRequest(
        configuration: configuration,
        sourceLanguage: "en",
        sourceLines: [AILyricsTranslationInputLine(index: 0, text: "A lyric")]
    )
    let payload = try #require(
        JSONSerialization.jsonObject(with: try JSONEncoder().encode(request)) as? [String: Any]
    )
    let messages = try #require(payload["messages"] as? [[String: String]])
    let userMessage = try #require(messages.last?["content"])

    #expect(userMessage.contains("Translate every lyric line into"))
    #expect(configuration.prompt == "   ")
}

@Test
func aiLyricsTranslationConfigurationReportsThePromptItWasGiven() throws {
    let configuration = try AILyricsTranslationPolicy.configuration(
        endpoint: "https://example.com/v1/chat/completions",
        model: "test-model",
        targetLanguage: "ja",
        prompt: ""
    )

    #expect(configuration.prompt.isEmpty)
}

@Test
func aiLyricsTranslationResolvesLoopbackEndpointsByAddress() {
    // The address decides, not the spelling. `URLComponents.host` keeps an
    // IPv6 literal bracketed, so `[::1]` never equals `::1`; and the same
    // interfaces have longer spellings too. Every one of these is loopback.
    func accepted(_ endpoint: String) -> Bool {
        do {
            _ = try AILyricsTranslationPolicy.validatedEndpoint(endpoint)
            return true
        } catch {
            return false
        }
    }

    #expect(accepted("http://localhost:8080/v1/chat/completions"))
    #expect(accepted("http://127.0.0.1:8080/v1/chat/completions"))
    #expect(accepted("http://[127.0.0.1]:8080/v1/chat/completions"))
    #expect(accepted("http://[localhost]:8080/v1/chat/completions"))
    #expect(accepted("http://[::1]:8080/v1/chat/completions"))
    #expect(accepted("http://[0:0:0:0:0:0:0:1]:8080/v1/chat/completions"))
    #expect(accepted("http://[::ffff:127.0.0.1]:8080/v1/chat/completions"))

    #expect(!accepted("http://192.168.1.10:8080/v1/chat/completions"))
    #expect(!accepted("http://[2001:db8::1]:8080/v1/chat/completions"))
    #expect(!accepted("http://api.example.com/v1/chat/completions"))
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
