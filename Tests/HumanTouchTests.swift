import CoreGraphics
import XCTest
@testable import AutoCore

final class HumanTouchTests: XCTestCase {
    private let screen = CGSize(width: 375, height: 812)

    func testTapsLandAFewPointsOffAndNeverFar() {
        var random = SystemRandomNumberGenerator()
        let target = NormalizedPoint(x: 0.5, y: 0.5)
        var offsets: [CGVector] = []
        for _ in 0..<2_000 {
            let point = HumanTouch.point(target, screen: screen, using: &random)
            offsets.append(CGVector(dx: (point.x - target.x) * screen.width, dy: (point.y - target.y) * screen.height))
        }
        let distances = offsets.map { ($0.dx * $0.dx + $0.dy * $0.dy).squareRoot() }
        XCTAssertLessThanOrEqual(distances.max() ?? 0, HumanTouch.maxOffset + 1e-9)
        XCTAssertGreaterThan(Set(offsets.map { "\($0.dx),\($0.dy)" }).count, 1_900, "every tap differs")
        let average = distances.reduce(0, +) / Double(distances.count)
        XCTAssertEqual(average, 1.9, accuracy: 0.3, "mostly a point or two")
        XCTAssertEqual(offsets.map(\.dx).reduce(0, +) / 2_000, 0, accuracy: 0.2, "no drift to one side")

        let corner = HumanTouch.point(NormalizedPoint(x: 0, y: 1), screen: nil, using: &random)
        XCTAssertTrue((0...1).contains(corner.x) && (0...1).contains(corner.y))
    }

    func testSwipesKeepTheirLengthAndDirection() {
        var random = SystemRandomNumberGenerator()
        let start = NormalizedPoint(x: 0.50, y: 0.74), end = NormalizedPoint(x: 0.50, y: 0.38)
        for _ in 0..<500 {
            let swipe = HumanTouch.swipe(from: start, to: end, duration: 0.55, releaseHold: 0.3,
                                         screen: screen, using: &random)
            let asked = CGVector(dx: 0, dy: (end.y - start.y) * screen.height)
            let made = CGVector(dx: (swipe.end.x - swipe.start.x) * screen.width,
                                dy: (swipe.end.y - swipe.start.y) * screen.height)
            XCTAssertLessThanOrEqual(hypot(made.dx - asked.dx, made.dy - asked.dy), HumanTouch.maxEndWobble + 1e-9)
            XCTAssertTrue((0.55 * 0.92...0.55 * 1.10).contains(swipe.duration))
            XCTAssertTrue((0.27...0.39).contains(swipe.releaseHold))
        }
        XCTAssertEqual(HumanTouch.swipe(from: start, to: end, duration: 0.15, releaseHold: 0,
                                        screen: screen, using: &random).releaseHold, 0)
    }

    func testTimingVariesButWaitsNeverGetShorter() {
        var random = SystemRandomNumberGenerator()
        let holds = (0..<500).map { _ in HumanTouch.milliseconds(55, using: &random) }
        XCTAssertTrue(holds.allSatisfy { (44...83).contains($0) })
        XCTAssertGreaterThan(Set(holds).count, 20)
        let waits = (0..<500).map { _ in HumanTouch.wait(0.6, using: &random) }
        XCTAssertTrue(waits.allSatisfy { (0.6...0.81).contains($0) })
        XCTAssertEqual(HumanTouch.wait(0, using: &random), 0, "a zero wait (tests, fast rules) stays zero")
        XCTAssertTrue((0..<500).allSatisfy { _ in (0.02...0.2).contains(HumanTouch.reaction(using: &random)) })
    }
}
