import CoreGraphics
import XCTest
@testable import Storyslice

final class TransformTests: XCTestCase {

    private let output = CGSize(width: 1080, height: 1920)
    private let landscape = CGSize(width: 1920, height: 1080)

    /// What an iPhone writes for a clip recorded in portrait: a 90-degree
    /// rotation applied to a landscape-stored buffer.
    private let rotate90 = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)

    private func map(_ point: CGPoint, _ transform: CGAffineTransform) -> CGPoint {
        point.applying(transform)
    }

    func testPortraitSourceFillsOutputAndNeedsNoBackground() {
        let geometry = Geometry.frameGeometry(naturalSize: landscape,
                                              preferredTransform: rotate90,
                                              outputSize: output)
        XCTAssertEqual(geometry.displaySize, CGSize(width: 1080, height: 1920))
        XCTAssertTrue(geometry.fillsOutput)
        XCTAssertFalse(geometry.needsBackground(for: .blur),
                       "already-vertical footage must skip the blur pass")
    }

    func testRotationIsBakedIntoTheSampling() {
        let geometry = Geometry.frameGeometry(naturalSize: landscape,
                                              preferredTransform: rotate90,
                                              outputSize: output)
        // Output centre must land on the centre of the stored buffer.
        let centre = map(CGPoint(x: 540, y: 960), geometry.outputToSourceFit)
        XCTAssertEqual(centre.x, 960, accuracy: 0.01)
        XCTAssertEqual(centre.y, 540, accuracy: 0.01)

        // Top-left of the upright frame is the bottom-left of the stored one.
        let topLeft = map(CGPoint(x: 0.5, y: 0.5), geometry.outputToSourceFit)
        XCTAssertEqual(topLeft.x, 0.5, accuracy: 0.01)
        XCTAssertEqual(topLeft.y, 1079.5, accuracy: 0.01)
    }

    func testLandscapeSourceLeavesBarsAndAsksForABackground() {
        let geometry = Geometry.frameGeometry(naturalSize: landscape,
                                              preferredTransform: .identity,
                                              outputSize: output)
        XCTAssertFalse(geometry.fillsOutput)
        XCTAssertTrue(geometry.needsBackground(for: .blur))
        XCTAssertFalse(geometry.needsBackground(for: .letterbox))
        XCTAssertFalse(geometry.needsBackground(for: .crop))

        // Fit scale is 1080/1920 = 0.5625, so the image occupies 607.5px of
        // 1920 and everything above y = 656.25 is bar.
        let inBar = map(CGPoint(x: 540, y: 100), geometry.outputToSourceFit)
        XCTAssertLessThan(inBar.y, 0, "a pixel in the bar must sample outside the source")

        let centre = map(CGPoint(x: 540, y: 960), geometry.outputToSourceFit)
        XCTAssertEqual(centre.x, 960, accuracy: 0.01)
        XCTAssertEqual(centre.y, 540, accuracy: 0.01)
    }

    func testCoverMappingNeverSamplesOutsideTheSource() {
        let geometry = Geometry.frameGeometry(naturalSize: landscape,
                                              preferredTransform: .identity,
                                              outputSize: output)
        for point in [CGPoint(x: 0.5, y: 0.5),
                      CGPoint(x: 1079.5, y: 0.5),
                      CGPoint(x: 0.5, y: 1919.5),
                      CGPoint(x: 1079.5, y: 1919.5)] {
            let source = map(point, geometry.outputToSourceCover)
            XCTAssertTrue((0...landscape.width).contains(source.x), "x out of range at \(point)")
            XCTAssertTrue((0...landscape.height).contains(source.y), "y out of range at \(point)")
        }
    }

    func testDegenerateSourceDoesNotDivideByZero() {
        let geometry = Geometry.frameGeometry(naturalSize: .zero,
                                              preferredTransform: .identity,
                                              outputSize: output)
        XCTAssertEqual(geometry.outputToSourceFit, .identity)
    }
}
