import CoreMedia
import Foundation

/// Splits a source duration into ordered, Story-postable ranges.
///
/// Pure value math — nothing from AVFoundation beyond `CMTime` — so it is
/// unit-testable without a device, a sample file, or a Metal context.
///
/// All arithmetic is done in integer units of the source's own timescale so
/// the segment lengths sum to the source duration *exactly*. Planning in
/// `Double` seconds accumulates rounding error and leaves a stray frame at the
/// end of long videos.
struct SegmentPlan: Equatable {

    /// If the trailing segment would be shorter than this fraction of the
    /// target length, every segment is levelled to equal duration instead.
    /// Nobody wants to post a two-second Story.
    static let minimumTailFraction = 0.2

    let segments: [CMTimeRange]

    var count: Int { segments.count }
    var isEmpty: Bool { segments.isEmpty }

    /// Total covered duration. Equals the source duration for any valid plan.
    var totalDuration: CMTime {
        segments.reduce(.zero) { CMTimeAdd($0, $1.duration) }
    }

    init(segments: [CMTimeRange]) {
        self.segments = segments
    }

    init(duration: CMTime, targetSegmentLength: CMTime) {
        guard duration.isNumeric, duration.value > 0,
              targetSegmentLength.isNumeric, targetSegmentLength.seconds > 0
        else {
            self.segments = []
            return
        }

        let scale = duration.timescale
        let total = duration.value
        let target = targetSegmentLength
            .convertScale(scale, method: .roundHalfAwayFromZero).value

        guard target > 0 else {
            self.segments = []
            return
        }

        if total <= target {
            self.segments = [CMTimeRange(start: .zero, duration: duration)]
            return
        }

        let n = Int((total + target - 1) / target)
        let tail = total - Int64(n - 1) * target

        var lengths: [Int64]
        if Double(tail) < Double(target) * Self.minimumTailFraction {
            // Level out: a 62s source at 60s becomes 31/31, not 60/2.
            let base = total / Int64(n)
            let remainder = Int(total % Int64(n))
            lengths = (0..<n).map { base + ($0 < remainder ? 1 : 0) }
        } else {
            lengths = Array(repeating: target, count: n - 1) + [tail]
        }

        var ranges: [CMTimeRange] = []
        ranges.reserveCapacity(lengths.count)
        var start: Int64 = 0
        for length in lengths {
            ranges.append(CMTimeRange(
                start: CMTime(value: start, timescale: scale),
                duration: CMTime(value: length, timescale: scale)))
            start += length
        }
        self.segments = ranges
    }
}
