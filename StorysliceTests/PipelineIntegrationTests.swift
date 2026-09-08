import AVFoundation
import XCTest
@testable import Storyslice

/// Needs a real Metal device: run on a device or an Apple-silicon simulator.
final class PipelineIntegrationTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("storyslice-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func export(sourceSize: CGSize,
                        transform: CGAffineTransform = .identity,
                        frames: Int = 150,
                        segmentSeconds: Double = 2,
                        fillMode: FillMode = .blur) async throws -> [ExportedSegment] {

        let url = try SyntheticSource.makeMovie(size: sourceSize,
                                                frameCount: frames,
                                                transform: transform)
        let source = try await AssetLoader.load(url: url)
        let plan = SegmentPlan(duration: source.duration,
                               targetSegmentLength: CMTime(seconds: segmentSeconds,
                                                           preferredTimescale: 600))
        var options = ExportOptions()
        options.fillMode = fillMode
        options.allowsThermalDownscale = false

        return try await VideoSlicer().export(source: source, plan: plan,
                                              options: options, into: directory,
                                              progress: { _ in })
    }

    func testLandscapeSourceSplitsIntoVerticalSegments() async throws {
        let segments = try await export(sourceSize: CGSize(width: 1920, height: 1080))
        // 5s at 2s segments: 2 + 2 + 1, the 1s tail being above the 20% floor.
        XCTAssertEqual(segments.count, 3)

        for segment in segments {
            let asset = AVURLAsset(url: segment.url)
            let track = try XCTUnwrap(asset.tracks(withMediaType: .video).first)

            XCTAssertEqual(track.naturalSize, CGSize(width: 1080, height: 1920))
            XCTAssertEqual(track.preferredTransform, .identity,
                           "rotation must be baked into pixels, not passed downstream")
            XCTAssertEqual(asset.duration.seconds, segment.range.duration.seconds, accuracy: 0.1)
            XCTAssertGreaterThan(
                try FileManager.default.attributesOfItem(atPath: segment.url.path)[.size] as? Int ?? 0,
                1024)
        }
    }

    func testPortraitSourceIsUprightAndNotLetterboxed() async throws {
        let rotate90 = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        let segments = try await export(sourceSize: CGSize(width: 1920, height: 1080),
                                        transform: rotate90,
                                        frames: 60)
        XCTAssertEqual(segments.count, 1)

        let asset = AVURLAsset(url: try XCTUnwrap(segments.first).url)
        let track = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        XCTAssertEqual(track.naturalSize, CGSize(width: 1080, height: 1920))
        XCTAssertEqual(track.preferredTransform, .identity)

        // A portrait source fills the canvas, so the top edge must carry image
        // rather than a black bar.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let image = try generator.copyCGImage(at: CMTime(value: 1, timescale: 30), actualTime: nil)
        XCTAssertFalse(isBlack(image, atX: 540, y: 20), "top edge should not be a letterbox bar")
    }

    func testCancellationLeavesNoFilesBehind() async throws {
        let url = try SyntheticSource.makeMovie(frameCount: 300)
        let source = try await AssetLoader.load(url: url)
        let plan = SegmentPlan(duration: source.duration,
                               targetSegmentLength: CMTime(seconds: 1, preferredTimescale: 600))

        let task = Task {
            try await VideoSlicer().export(source: source, plan: plan,
                                           options: ExportOptions(), into: directory,
                                           progress: { _ in })
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()

        do {
            _ = try await task.value
        } catch is CancellationError {
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            XCTAssertTrue(leftovers.isEmpty, "cancel must not leave partial files: \(leftovers)")
            return
        }
        // Fast machines can finish before the cancel lands; that is not a failure.
    }

    private func isBlack(_ image: CGImage, atX x: Int, y: Int) -> Bool {
        guard let data = image.dataProvider?.data,
              let pointer = CFDataGetBytePtr(data) else { return true }
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        let sum = Int(pointer[offset]) + Int(pointer[offset + 1]) + Int(pointer[offset + 2])
        return sum < 24
    }
}
