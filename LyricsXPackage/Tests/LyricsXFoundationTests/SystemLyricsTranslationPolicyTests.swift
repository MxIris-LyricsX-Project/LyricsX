import Testing
@testable import LyricsXFoundation

@Test(arguments: [
    ("我们一起\n走过的路", "我们一起 走过的路"),
    ("  走过的路\t", "走过的路"),
    ("走过的\r\n路", "走过的 路"),
])
func aTranslationIsStoredOnOneLine(returned: String, stored: String) {
    #expect(SystemLyricsTranslationPolicy.storableTranslation(returned) == stored)
}

@Test(arguments: ["", "   ", "\n"])
func anEmptyTranslationIsNotStored(returned: String) {
    #expect(SystemLyricsTranslationPolicy.storableTranslation(returned) == nil)
}

@Test(arguments: [
    // Already in the target language.
    ("我们一起走过的路", "我们一起走过的路"),
    // Romanized Japanese, which the models hand back as they get it.
    ("Kimi no namae wo yonda", " Kimi no namae wo yonda "),
])
func aLineHandedBackAsItWentIsUnchanged(translation: String, sourceText: String) {
    #expect(SystemLyricsTranslationPolicy.isUnchanged(translation, from: sourceText))
}

@Test
func aTranslatedLineIsNotUnchanged() {
    #expect(!SystemLyricsTranslationPolicy.isUnchanged("叫了你的名字", from: "君の名前を呼んだ"))
}
