import CoreMedia
import XCTest
@testable import Storyslice

final class SegmentPlanTests: XCTestCase {

    private func time(_ seconds: Double, scale: CMTimeScale = 600) -> CMTime {
        CMTime(value: CMTimeValue((seconds * Double(scale)).rounded()), timescale: scale)
    }

    private func seconds(_ plan: SegmentPlan) -> [Double] {
        plan.segments.map { ($0.duration.seconds * 1000).rounded() / 1000 }
    }

    func testSourceShorterThanOneSegmentIsNotSplit() {
        let plan = SegmentPlan(duration: time(9), targetSegmentLength: time(60))
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(seconds(plan), [9])
    }

    func testExactMultipleSplitsEvenly() {
        let plan = SegmentPlan(duration: time(180), targetSegmentLength: time(60))
        XCTAssertEqual(seconds(plan), [60, 60, 60])
    }

    /// 3m20s at 60s. The approved spec said 60/60/60/40; the arithmetic says 20.
    func testUsefulTailIsKept() {
        let plan = SegmentPlan(duration: time(200), targetSegmentLength: time(60))
        XCTAssertEqual(seconds(plan), [60, 60, 60, 20])
    }

    func testStubTailIsLevelledAway() {
        let plan = SegmentPlan(duration: time(62), targetSegmentLength: time(60))
        XCTAssertEqual(seconds(plan), [31, 31])
    }

    func testTailExactlyAtThresholdIsKept() {
        // 60s target, 20% floor = 12s tail.
        let plan = SegmentPlan(duration: time(72), targetSegmentLength: time(60))
        XCTAssertEqual(seconds(plan), [60, 12])
    }

    func testZeroAndNegativeInputsProduceNoPlan() {
        XCTAssertTrue(SegmentPlan(duration: .zero, targetSegmentLength: time(60)).isEmpty)
        XCTAssertTrue(SegmentPlan(duration: time(60), targetSegmentLength: .zero).isEmpty)
        XCTAssertTrue(SegmentPlan(duration: .invalid, targetSegmentLength: time(60)).isEmpty)
    }

    /// The property that actually matters: a plan never loses or invents a
    /// frame, at any duration, in any timescale.
    func testSegmentsAreContiguousAndSumExactly() {
        for rawDuration in stride(from: 0.5, through: 400.0, by: 3.7) {
            for target in [15.0, 30.0, 60.0] {
                let duration = time(rawDuration, scale: 30_000)
                let plan = SegmentPlan(duration: duration,
                                       targetSegmentLength: time(target, scale: 30_000))
                XCTAssertFalse(plan.isEmpty)
                XCTAssertEqual(plan.totalDuration, duration,
                               "durations must sum exactly at \(rawDuration)s / \(target)s")
                XCTAssertEqual(plan.segments.first?.start, .zero)
                for (a, b) in zip(plan.segments, plan.segments.dropFirst()) {
                    XCTAssertEqual(a.end, b.start, "gap at \(rawDuration)s / \(target)s")
                }
            }
        }
    }
}
