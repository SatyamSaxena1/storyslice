import AVFoundation
import CoreGraphics
import XCTest

/// Builds test movies on the fly so the pipeline can be verified without
/// checking sample media into the repo.
enum SyntheticSource {

    /// Writes a movie whose every frame is a flat colour derived from its
    /// index, so a decoded frame can be identified by a single pixel read.
    @discardableResult
    static func makeMovie(size: CGSize = CGSize(width: 1920, height: 1080),
                          frameCount: Int = 150,
                          fps: Int32 = 30,
                          transform: CGAffineTransform = .identity,
                          named name: String = "synthetic") throws -> URL {

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).mp4")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ])
        input.expectsMediaDataInRealTime = false
        input.transform = transform
        writer.add(input)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ])

        guard writer.startWriting() else { throw writer.error ?? SyntheticError.writeFailed }
        writer.startSession(atSourceTime: .zero)

        for index in 0..<frameCount {
            while !input.isReadyForMoreMediaData { usleep(1000) }
            guard let pool = adaptor.pixelBufferPool else { throw SyntheticError.writeFailed }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
            guard let pixels = buffer else { throw SyntheticError.writeFailed }
            fill(pixels, with: colour(for: index))
            adaptor.append(pixels, withPresentationTime:
                CMTime(value: CMTimeValue(index), timescale: fps))
        }

        input.markAsFinished()
        let done = XCTestExpectation(description: "write")
        writer.finishWriting { done.fulfill() }
        XCTWaiter().wait(for: [done], timeout: 60)
        guard writer.status == .completed else { throw writer.error ?? SyntheticError.writeFailed }
        return url
    }

    /// Distinct, well-separated colours so H.264 quantisation cannot make two
    /// frames indistinguishable.
    static func colour(for index: Int) -> (b: UInt8, g: UInt8, r: UInt8) {
        (b: UInt8((index * 7) % 200 + 20),
         g: UInt8((index * 11) % 200 + 20),
         r: UInt8((index * 13) % 200 + 20))
    }

    private static func fill(_ buffer: CVPixelBuffer, with colour: (b: UInt8, g: UInt8, r: UInt8)) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let row = pixels + y * bytesPerRow
            for x in 0..<width {
                let p = row + x * 4
                p[0] = colour.b; p[1] = colour.g; p[2] = colour.r; p[3] = 255
            }
        }
    }

    enum SyntheticError: Error { case writeFailed }
}
