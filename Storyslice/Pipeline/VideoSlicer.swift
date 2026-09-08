import AVFoundation
import CoreVideo
import Foundation

struct ExportOptions {
    var outputSize = CGSize(width: 1080, height: 1920)
    var fillMode: FillMode = .blur
    var bitrate = 10_000_000
    /// Dropped to 720x1280 when the device is already hot.
    var allowsThermalDownscale = true
}

struct ExportedSegment {
    let index: Int
    let url: URL
    let range: CMTimeRange
}

enum ExportError: LocalizedError {
    case writerFailed(Error?)
    case readerFailed(Error?)
    case noPixelBufferPool
    case emptyPlan

    var errorDescription: String? {
        switch self {
        case .writerFailed(let e): return e?.localizedDescription ?? "The exporter stopped unexpectedly."
        case .readerFailed(let e): return e?.localizedDescription ?? "The video could not be read."
        case .noPixelBufferPool: return "The exporter could not allocate video frames."
        case .emptyPlan: return "That video is too short to split."
        }
    }
}

/// Reads the source exactly once and writes N segment files from that single
/// pass, switching writers as sample timestamps cross each planned boundary.
///
/// The obvious alternative -- one `AVAssetExportSession` per segment with a
/// `timeRange` -- decodes the whole source once per segment and cannot do
/// colour-managed rendering or compositing at all.
final class VideoSlicer {

    private let queue = DispatchQueue(label: "storyslice.export")

    func export(source: VideoSourceInfo,
                plan: SegmentPlan,
                options: ExportOptions,
                into directory: URL,
                progress: @escaping (Double) -> Void) async throws -> [ExportedSegment] {

        guard !plan.isEmpty else { throw ExportError.emptyPlan }

        let outputSize = resolvedOutputSize(options)
        let renderer = try MetalRenderer(source: source,
                                         outputSize: outputSize,
                                         fillMode: options.fillMode)

        let reader = try AVAssetReader(asset: source.asset)
        let videoOutput = AVAssetReaderTrackOutput(
            track: source.videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: source.readerPixelFormat,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ])
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack = source.audioTrack {
            let output = AVAssetReaderTrackOutput(track: audioTrack,
                                                  outputSettings: AudioTranscoder.readerSettings)
            output.alwaysCopiesSampleData = false
            reader.add(output)
            audioOutput = output
        }

        guard reader.startReading() else { throw ExportError.readerFailed(reader.error) }
        defer { if reader.status == .reading { reader.cancelReading() } }

        var produced: [ExportedSegment] = []
        var inFlight: (writer: AVAssetWriter, url: URL)?
        let totalSeconds = max(plan.totalDuration.seconds, 0.001)

        var videoSample = videoOutput.copyNextSampleBuffer()
        var audioSample = audioOutput?.copyNextSampleBuffer()

        do {
            for (index, range) in plan.segments.enumerated() {
                try Task.checkCancellation()

                let url = directory.appendingPathComponent(
                    String(format: "%@-%02d.mp4", sanitised(source.displayName), index + 1))
                try? FileManager.default.removeItem(at: url)

                let segment = try makeWriter(url: url,
                                             outputSize: outputSize,
                                             options: options,
                                             source: source)
                guard segment.writer.startWriting() else {
                    throw ExportError.writerFailed(segment.writer.error)
                }
                segment.writer.startSession(atSourceTime: range.start)
                inFlight = (segment.writer, url)

                let end = range.end
                while true {
                    try Task.checkCancellation()

                    let videoTime = videoSample.map(CMSampleBufferGetPresentationTimeStamp)
                    let audioTime = audioSample.map(CMSampleBufferGetPresentationTimeStamp)
                    let videoPending = videoTime.map { $0 < end } ?? false
                    let audioPending = audioTime.map { $0 < end } ?? false
                    if !videoPending && !audioPending { break }

                    // Take whichever stream is behind, so the file comes out
                    // interleaved rather than all-video-then-all-audio (which
                    // is valid but makes the writer buffer a whole segment).
                    // A PCM block straddling the boundary lands wholly in the
                    // earlier segment: up to ~90 ms of overshoot, inaudible,
                    // and it keeps the next segment starting cleanly.
                    let takeVideo = (videoPending && audioPending)
                        ? videoTime! <= audioTime!
                        : videoPending

                    if takeVideo, let sample = videoSample {
                        await segment.videoInput.waitUntilReady(on: queue)
                        try append(sample, to: segment.adaptor,
                                   writer: segment.writer, renderer: renderer)
                        videoSample = videoOutput.copyNextSampleBuffer()
                        let done = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                        progress(min(max(done / totalSeconds, 0), 1))
                    } else if let sample = audioSample, let input = segment.audioInput {
                        await input.waitUntilReady(on: queue)
                        guard input.append(sample) else {
                            throw ExportError.writerFailed(segment.writer.error)
                        }
                        audioSample = audioOutput?.copyNextSampleBuffer()
                    } else {
                        // No audio input on this writer; drop the sample and move on.
                        audioSample = audioOutput?.copyNextSampleBuffer()
                    }
                }

                segment.videoInput.markAsFinished()
                segment.audioInput?.markAsFinished()
                await segment.writer.finishWritingAsync()
                guard segment.writer.status == .completed else {
                    throw ExportError.writerFailed(segment.writer.error)
                }
                inFlight = nil
                produced.append(ExportedSegment(index: index, url: url, range: range))

                // ponytail: pause between segments when the device is critical
                // rather than switching resolution mid-set. Mixed-resolution
                // Stories look worse than a slow export. Revisit if users on
                // older hardware report exports never finishing.
                if ProcessInfo.processInfo.thermalState == .critical {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        } catch {
            // Cancel leaves nothing half-written behind: kill the in-flight
            // writer, then remove every file this export produced.
            if let inFlight = inFlight {
                if inFlight.writer.status == .writing { inFlight.writer.cancelWriting() }
                try? FileManager.default.removeItem(at: inFlight.url)
            }
            for segment in produced { try? FileManager.default.removeItem(at: segment.url) }
            throw error
        }

        if reader.status == .failed { throw ExportError.readerFailed(reader.error) }
        progress(1)
        return produced
    }

    // MARK: - Per-segment writer

    private struct SegmentWriter {
        let writer: AVAssetWriter
        let videoInput: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let audioInput: AVAssetWriterInput?
    }

    private func makeWriter(url: URL,
                            outputSize: CGSize,
                            options: ExportOptions,
                            source: VideoSourceInfo) throws -> SegmentWriter {

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: options.bitrate,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoMaxKeyFrameIntervalKey: 60,
            AVVideoAllowFrameReorderingKey: true
        ]
        if source.nominalFrameRate > 0 {
            compression[AVVideoExpectedSourceFrameRateKey] = Int(source.nominalFrameRate.rounded())
        }

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(outputSize.width),
            AVVideoHeightKey: Int(outputSize.height),
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ])
        videoInput.expectsMediaDataInRealTime = false
        // Deliberately left at identity. The source rotation is baked into the
        // rendered pixels; passing a transform downstream as well makes some
        // consumers -- Instagram among them -- render the clip sideways.
        videoInput.transform = .identity

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(outputSize.width),
                kCVPixelBufferHeightKey as String: Int(outputSize.height),
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ])
        guard writer.canAdd(videoInput) else { throw ExportError.writerFailed(writer.error) }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if let track = source.audioTrack {
            let input = AVAssetWriterInput(mediaType: .audio,
                                           outputSettings: AudioTranscoder.writerSettings(for: track))
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        return SegmentWriter(writer: writer, videoInput: videoInput,
                             adaptor: adaptor, audioInput: audioInput)
    }

    private func append(_ sample: CMSampleBuffer,
                        to adaptor: AVAssetWriterInputPixelBufferAdaptor,
                        writer: AVAssetWriter,
                        renderer: MetalRenderer) throws {
        guard let sourceBuffer = CMSampleBufferGetImageBuffer(sample) else { return }
        guard let pool = adaptor.pixelBufferPool else { throw ExportError.noPixelBufferPool }

        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination)
                == kCVReturnSuccess,
              let output = destination else { throw ExportError.noPixelBufferPool }

        try renderer.render(source: sourceBuffer, into: output)

        // The real presentation timestamp, never a synthesised one: iPhone
        // low-light and Cinematic footage is variable frame rate and will drift
        // audibly out of sync within a minute if frames are evenly spaced.
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        guard adaptor.append(output, withPresentationTime: time) else {
            throw ExportError.writerFailed(writer.error)
        }
    }

    // MARK: - Helpers

    private func resolvedOutputSize(_ options: ExportOptions) -> CGSize {
        guard options.allowsThermalDownscale else { return options.outputSize }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return CGSize(width: 720, height: 1280)
        default: return options.outputSize
        }
    }

    private func sanitised(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return cleaned.isEmpty ? "story" : String(cleaned.prefix(40))
    }
}
