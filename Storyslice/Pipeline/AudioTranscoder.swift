import AVFoundation

/// Audio is decoded to PCM and re-encoded to AAC rather than passed through.
///
/// Compressed AAC frames are 1024 samples long and our cut points land
/// wherever the user asked, so a pass-through would either shift the cut to
/// the nearest frame boundary or emit a truncated first frame. The ~21 ms of
/// encoder priming delay this costs per segment is below the threshold of
/// perception, and Instagram re-encodes the audio again anyway.
enum AudioTranscoder {

    static let readerSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false
    ]

    static func writerSettings(for track: AVAssetTrack) -> [String: Any] {
        var sampleRate = 44_100.0
        var channels = 2

        if let description = track.formatDescriptions.first as? CMAudioFormatDescription,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
            if asbd.mSampleRate > 0 { sampleRate = asbd.mSampleRate }
            if asbd.mChannelsPerFrame > 0 { channels = Int(asbd.mChannelsPerFrame) }
        }

        // Downmix anything above stereo. Encoding >2 channels to AAC needs an
        // explicit channel layout, and Stories are stereo at best.
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: min(channels, 2),
            AVEncoderBitRateKey: 128_000
        ]
    }
}
