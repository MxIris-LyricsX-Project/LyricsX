import Foundation

/// Where one step of the current lyrics' offset takes it: a click on the status
/// menu's stepper, or the shortcuts that raise and lower the offset.
public enum LyricsOffsetStepPolicy {
    public enum Direction: Sendable {
        /// A larger offset: the lyrics show earlier.
        case increase
        /// A smaller offset: the lyrics show later.
        case decrease
    }

    /// The milliseconds one step covers.
    public static let step = 100

    /// The offsets, in milliseconds, the status menu takes.
    public static let range: ClosedRange<Int> = -10_000 ... 10_000

    /// A step goes to the next multiple of ``step`` in its direction.
    ///
    /// Lyrics can come with an offset of their own — Kugou's carry ones like
    /// 51 ms — and adding ``step`` to it kept the odd milliseconds for good:
    /// from 51 a step went to 151 or -49, and never back to 0.
    ///
    /// A step never takes the offset out of ``range``. An offset already
    /// outside it, written into the lyrics file by hand, only steps back
    /// toward it.
    public static func offset(steppedFrom offset: Int, direction: Direction) -> Int {
        let quotient = offset / step
        let remainder = offset % step
        switch direction {
        case .increase:
            let nextMultiple = (remainder < 0 ? quotient : quotient + 1) * step
            return max(offset, min(nextMultiple, range.upperBound))
        case .decrease:
            let previousMultiple = (remainder > 0 ? quotient : quotient - 1) * step
            return min(offset, max(previousMultiple, range.lowerBound))
        }
    }
}
