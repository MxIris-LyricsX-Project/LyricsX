import Foundation
import Testing
@testable import LyricsXFoundation

// Which parts of a desktop lyrics line get furigana and romaji, and how the
// reading of a word spreads over its kanji. The scope tests go through the
// system's language detection (CFStringTokenizer), as the desktop lyrics do,
// so a macOS release that classifies these lines differently shows up here.

private func range(of part: String, in line: String) -> NSRange {
    (line as NSString).range(of: part)
}

/// "word→reading" for each span, so a failure reads as text.
private func furigana(_ token: String, _ reading: String) -> [String] {
    FuriganaAlignment.spans(token: token, reading: reading).map {
        "\((token as NSString).substring(with: $0.range))→\($0.reading)"
    }
}

// MARK: - Scope

@Test
func aJapaneseLineIsAnnotatedWhole() {
    let line = "君の名前を呼んだ"

    #expect(JapaneseAnnotationScope(line: line) == .wholeLine)
    #expect(JapaneseAnnotationScope(line: line).ranges(in: line) == [NSRange(location: 0, length: 8)])
}

@Test
func aLineWithoutJapaneseIsNotAnnotated() {
    #expect(JapaneseAnnotationScope(line: "我的 love song") == .noJapanese)
}

/// Chinese lyrics borrow の from Japanese. Before, one kana anywhere made the
/// whole line's kanji read as Japanese (在 ざい, 我 が).
@Test(arguments: ["在那个夏天の风里我们一起奔跑", "今天也要元气满满の说"])
func aChineseLineWithAKanaIsNotAnnotated(line: String) {
    #expect(JapaneseAnnotationScope(line: line) == .noJapanese)
}

/// The ノ of a kaomoji is katakana, but no Japanese word: before, it got the
/// romaji "no".
@Test
func aKaomojiDoesNotMakeAnEnglishLineJapanese() {
    #expect(JapaneseAnnotationScope(line: "Love you ヽ(・∀・)ノ") == .noJapanese)
}

/// The case the per-run scope exists for: an English-heavy line that the
/// system classifies as another language still gets its Japanese annotated.
@Test(arguments: [
    ("Oh darling darling 止まらない dance", "止まらない"),
    ("叶わない oh darling darling", "叶わない"),
    ("I said ありがとう to you", "ありがとう"),
])
func theJapaneseRunOfAMixedLineIsAnnotated(line: String, run: String) {
    #expect(JapaneseAnnotationScope(line: line) == .japaneseRuns([range(of: run, in: line)]))
}

// MARK: - Furigana alignment

@Test
func furiganaSitsOnEachKanjiRunBetweenTheKanaOfTheWord() {
    #expect(furigana("日の出", "ひので") == ["日→ひ", "出→で"])
    #expect(furigana("乗り込んで", "のりこんで") == ["乗→の", "込→こ"])
}

@Test
func anIterationMarkBelongsToTheKanjiBeforeIt() {
    #expect(furigana("時々", "ときどき") == ["時々→ときどき"])
}

/// ヶ, 〆 and kanji outside the basic block (Extension A and B, the
/// compatibility block) used to count as kana that had to appear in the
/// reading as written, so these words lost their furigana altogether.
@Test(arguments: [
    ("ヶ月", "かげつ", ["ヶ月→かげつ"]),
    ("関ヶ原", "せきがはら", ["関ヶ原→せきがはら"]),
    ("〆切", "しめきり", ["〆切→しめきり"]),
    ("山﨑", "やまざき", ["山﨑→やまざき"]),
    ("𠮷野", "よしの", ["𠮷野→よしの"]),
    ("㐂び", "よろこび", ["㐂→よろこ"]),
])
func smallKeAndRarerKanjiAreReadAsKanji(token: String, reading: String, expected: [String]) {
    #expect(furigana(token, reading) == expected)
}

@Test
func aWordWithoutKanjiGetsNoFurigana() {
    #expect(furigana("ありがとう", "ありがとう") == [])
}

@Test
func aReadingThatDoesNotFitTheWrittenKanaGetsNoFurigana() {
    #expect(furigana("日の出", "にちじつ") == [])
}
