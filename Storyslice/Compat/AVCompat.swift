import AVFoundation

enum AVCompatError: LocalizedError {
    case propertyLoadFailed(String, Error?)
    case noVideoTrack
    case unsupportedSource(String)

    var errorDescription: String? {
        switch self {
        case .propertyLoadFailed(let key, let underlying):
            return "Could not read \(key) from the video. \(underlying?.localizedDescription ?? "")"
        case .noVideoTrack:
            return "That file has no video track."
        case .unsupportedSource(let why):
            return "That video cannot be processed: \(why)"
        }
    }
}

extension AVAsynchronousKeyValueLoading {

    /// The one place `loadValuesAsynchronously` is called.
    ///
    /// iOS 16 introduced `load(_:)`, but it is unavailable on our floor of
    /// iOS 13. Wrapping the old API in a continuation once means the pipeline
    /// is written against `async` throughout and contains no `#available`.
    /// Swift concurrency itself back-deploys to iOS 13.0 (Xcode 13.2+), at the
    /// cost of an embedded concurrency runtime in the bundle.
    func loadPropertyValues(_ keys: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            loadValuesAsynchronously(forKeys: keys) {
                for key in keys {
                    var error: NSError?
                    if self.statusOfValue(forKey: key, error: &error) != .loaded {
                        cont.resume(throwing: AVCompatError.propertyLoadFailed(key, error))
                        return
                    }
                }
                cont.resume()
            }
        }
    }
}

extension AVAssetWriter {
    /// `finishWriting(completionHandler:)` never calls back twice, so a checked
    /// continuation is safe here.
    func finishWritingAsync() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            finishWriting { cont.resume() }
        }
    }
}

extension AVAssetWriterInput {
    /// Suspend until the input will accept more samples.
    ///
    /// ponytail: 4 ms polling rather than a `requestMediaDataWhenReady` pump.
    /// With `expectsMediaDataInRealTime == false` the input is almost always
    /// ready, so this costs a handful of hops per export. Move to the callback
    /// pump if profiling ever shows real time spent here.
    func waitUntilReady(on queue: DispatchQueue) async {
        while !isReadyForMoreMediaData {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                queue.asyncAfter(deadline: .now() + 0.004) { cont.resume() }
            }
        }
    }
}
