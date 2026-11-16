import Testing
@testable import LyricsXFoundation

// A step of the lyrics offset used to add or take away 100 ms. Lyrics that
// came with an offset of their own — Kugou's "[offset:51]" — kept its odd
// milliseconds for good: from 51 the stepper went to 151 or -49, and the
// offset could not be stepped back to 0.

private typealias Direction = LyricsOffsetStepPolicy.Direction

@Test
func stepsFromAnOffsetTheLyricsCameWithReachZero() {
    #expect(LyricsOffsetStepPolicy.offset(steppedFrom: 51, direction: .decrease) == 0)
    #expect(LyricsOffsetStepPolicy.offset(steppedFrom: 51, direction: .increase) == 100)
    #expect(LyricsOffsetStepPolicy.offset(steppedFrom: -49, direction: .increase) == 0)
    #expect(LyricsOffsetStepPolicy.offset(steppedFrom: -49, direction: .decrease) == -100)
}

@Test(arguments: [
    (offset: 0, direction: Direction.increase, expected: 100),
    (offset: 0, direction: Direction.decrease, expected: -100),
    (offset: 300, direction: Direction.increase, expected: 400),
    (offset: 300, direction: Direction.decrease, expected: 200),
    (offset: -300, direction: Direction.increase, expected: -200),
    (offset: -300, direction: Direction.decrease, expected: -400),
])
func aRoundOffsetStepsAWholeStep(offset: Int, direction: LyricsOffsetStepPolicy.Direction, expected: Int) {
    #expect(LyricsOffsetStepPolicy.offset(steppedFrom: offset, direction: direction) == expected)
}

@Test(arguments: [
    (offset: 151, direction: Direction.increase, expected: 200),
    (offset: 151, direction: Direction.decrease, expected: 100),
    (offset: -208, direction: Direction.increase, expected: -200),
    (offset: -208, direction: Direction.decrease, expected: -300),
    (offset: 1, direction: Direction.decrease, expected: 0),
    (offset: -1, direction: Direction.increase, expected: 0),
])
func anOddOffsetStepsToTheNextRoundOne(offset: Int, direction: LyricsOffsetStepPolicy.Direction, expected: Int) {
    #expect(LyricsOffsetStepPolicy.offset(steppedFrom: offset, direction: direction) == expected)
}

@Test
func aStepStopsAtTheEndOfTheRange() {
    #expect(LyricsOffsetStepPolicy.offset(steppedFrom: 10_000, direction: .increase) == 10_000)
    #expect(LyricsOffsetStepPolicy.offset(steppedFrom: -10_000, direction: .decrease) == -10_000)
    #expect(LyricsOffsetStepPolicy.offset(steppedFrom: 9_951, direction: .increase) == 10_000)
}

@Test
func anOffsetPastTheRangeOnlyStepsBackTowardIt() {
    // Typed into the lyrics file by hand, or by another app.
    #expect(LyricsOffsetStepPolicy.offset(steppedFrom: 12_000, direction: .increase) == 12_000)
    #expect(LyricsOffsetStepPolicy.offset(steppedFrom: 12_000, direction: .decrease) == 11_900)
    #expect(LyricsOffsetStepPolicy.offset(steppedFrom: -12_000, direction: .decrease) == -12_000)
    #expect(LyricsOffsetStepPolicy.offset(steppedFrom: -12_000, direction: .increase) == -11_900)
}
