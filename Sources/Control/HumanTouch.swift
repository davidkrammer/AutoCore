import CoreGraphics
import Foundation

/// Automated touches vary a little, like a finger's: each tap lands a few
/// points off its target and is held a little longer or shorter, and the
/// waits around touches are never quite the same. Taps made by hand from the
/// Mac stay exact.
enum HumanTouch {
    /// One standard deviation of a tap's offset, in iPhone points (three
    /// pixels each on an iPhone XS).
    static let spread = 1.5
    /// The farthest a tap may land from its target, in points.
    static let maxOffset = 4.0
    /// The farthest the end of a swipe may wander on its own, in points, so
    /// a swipe still travels almost exactly as far as asked.
    static let maxEndWobble = 1.0
    /// Screen size in points while the iPhone's isn't known (iPhone XS).
    static let fallbackScreen = CGSize(width: 375, height: 812)

    /// `point` moved by a random offset, mostly within a point or two.
    static func point(_ point: NormalizedPoint, screen: CGSize?,
                      using random: inout some RandomNumberGenerator) -> NormalizedPoint {
        moved(point, by: offset(limit: maxOffset, using: &random), screen: screen)
    }

    /// A random offset in points, normally distributed and cut off at `limit`.
    static func offset(limit: Double, using random: inout some RandomNumberGenerator) -> CGVector {
        // Box–Muller: a normally distributed distance in a random direction.
        let u = Double.random(in: Double.ulpOfOne..<1, using: &random)
        let distance = min(spread * (-2 * log(u)).squareRoot(), limit)
        let angle = Double.random(in: 0..<(2 * .pi), using: &random)
        return CGVector(dx: distance * cos(angle), dy: distance * sin(angle))
    }

    struct Swipe: Equatable {
        var start: NormalizedPoint
        var end: NormalizedPoint
        var duration: Double
        var releaseHold: Double
    }

    /// The whole swipe moves by one offset, so lists still scroll by the
    /// same distance; the end wobbles by at most a point, and the swipe is
    /// a little faster or slower.
    static func swipe(from start: NormalizedPoint, to end: NormalizedPoint, duration: Double,
                      releaseHold: Double, screen: CGSize?,
                      using random: inout some RandomNumberGenerator) -> Swipe {
        let shift = offset(limit: maxOffset, using: &random)
        let wobble = offset(limit: maxEndWobble, using: &random)
        return Swipe(start: moved(start, by: shift, screen: screen),
                     end: moved(end, by: CGVector(dx: shift.dx + wobble.dx, dy: shift.dy + wobble.dy),
                                screen: screen),
                     duration: duration * Double.random(in: 0.92...1.10, using: &random),
                     releaseHold: releaseHold > 0
                         ? releaseHold * Double.random(in: 0.9...1.3, using: &random) : 0)
    }

    /// How long a finger stays down, or rests between quick taps, for
    /// `milliseconds` that would otherwise always be the same: 80–150 %.
    static func milliseconds(_ milliseconds: Int, using random: inout some RandomNumberGenerator) -> Int {
        max(1, Int((Double(milliseconds) * Double.random(in: 0.8...1.5, using: &random)).rounded()))
    }

    /// A wait after a touch, never shorter than `seconds` (the screen may
    /// need it) and up to 35 % longer, mostly a little.
    static func wait(_ seconds: Double, using random: inout some RandomNumberGenerator) -> Double {
        guard seconds > 0 else { return seconds }
        let r = Double.random(in: 0..<1, using: &random)
        return seconds * (1 + 0.35 * r * r)
    }

    static func wait(_ seconds: Double) -> Double {
        var random = SystemRandomNumberGenerator()
        return wait(seconds, using: &random)
    }

    /// A short moment before each touch, 20–200 ms, mostly short.
    static func reaction(using random: inout some RandomNumberGenerator) -> Double {
        let r = Double.random(in: 0..<1, using: &random)
        return 0.02 + 0.18 * r * r
    }

    private static func moved(_ point: NormalizedPoint, by offset: CGVector, screen: CGSize?) -> NormalizedPoint {
        let size = screen.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil } ?? fallbackScreen
        return NormalizedPoint(x: point.x + offset.dx / size.width, y: point.y + offset.dy / size.height).clamped
    }
}
