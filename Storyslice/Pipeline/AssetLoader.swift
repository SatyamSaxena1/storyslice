import AVFoundation
import CoreGraphics

enum TransferFunction: UInt32 {
    case bt709 = 0
    case hlg = 1
    case pq = 2

    var isHDR: Bool { self != .bt709 }
}

enum YCbCrMatrix {
    case bt601, bt709, bt2020

    /// Columns are (Y, Cb, Cr); Cb/Cr are expected pre-centred around zero.
    var coefficients: (r: (Float, Float, Float),
                       g: (Float, Float, Float),
                       b: (Float, Float, Float)) {
        switch self {
        case .bt601:  return ((1, 0, 1.402),    (1, -0.344136, -0.714136), (1, 1.772, 0))
        case .bt709:  return ((1, 0, 1.5748),   (1, -0.187324, -0.468124), (1, 1.8556, 0))
        case .bt2020: return ((1, 0, 1.4746),   (1, -0.164553, -0.571353), (1, 1.8814, 0))
        }
    }
}

/// Everything the pipeline needs to know about a source, resolved once.
struct VideoSourceInfo {
    let asset: AVAsset
    let videoTrack: AVAssetTrack
    let audioTrack: AVAssetTrack?
    let duration: CMTime
    let naturalSize: CGSize
    let preferredTransform: CGAffineTransform
    let nominalFrameRate: Float
    let transfer: TransferFunction
    let matrix: YCbCrMatrix
    let isTenBit: Bool
    let creationDate: Date?
    let displayName: String

    /// The reader pixel format to request. Asking for 8-bit on an HDR source
    /// makes VideoToolbox tone-map it badly behind our back; asking for 10-bit
    /// on SDR wastes bandwidth.
    var readerPixelFormat: OSType {
        isTenBit
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }
}

enum AssetLoader {

    static func load(url: URL) async throws -> VideoSourceInfo {
        try await load(asset: AVURLAsset(url: url,
                                         options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]),
                       displayName: url.deletingPathExtension().lastPathComponent)
    }

    static func load(asset: AVAsset, displayName: String) async throws -> VideoSourceInfo {
        try await asset.loadPropertyValues(["tracks", "duration", "creationDate"])

        guard let video = asset.tracks(withMediaType: .video).first else {
            throw AVCompatError.noVideoTrack
        }
        let audio = asset.tracks(withMediaType: .audio).first

        try await video.loadPropertyValues(
            ["naturalSize", "preferredTransform", "nominalFrameRate", "formatDescriptions"])
        if let audio = audio {
            try await audio.loadPropertyValues(["formatDescriptions"])
        }

        guard let format = video.formatDescriptions.first as? CMFormatDescription else {
            throw AVCompatError.unsupportedSource("its video track has no format description")
        }
        let subType = CMFormatDescriptionGetMediaSubType(format)

        let transfer = transferFunction(of: format)
        let creation = asset.creationDate.flatMap(dateValue(of:))

        return VideoSourceInfo(
            asset: asset,
            videoTrack: video,
            audioTrack: audio,
            duration: asset.duration,
            naturalSize: video.naturalSize,
            preferredTransform: video.preferredTransform,
            nominalFrameRate: video.nominalFrameRate,
            transfer: transfer,
            matrix: ycbcrMatrix(of: format, transfer: transfer),
            // Proxy, not ground truth: HDR footage is always 10-bit, and so is
            // every ProRes flavour the iPhone can record. A 10-bit SDR HEVC
            // file would be misread as 8-bit and come out banded — rare enough
            // to not be worth parsing the sample description for.
            isTenBit: transfer.isHDR || isProRes(subType),
            creationDate: creation,
            displayName: displayName)
    }

    // MARK: - Format description spelunking

    private static func transferFunction(of format: CMFormatDescription) -> TransferFunction {
        let value = CMFormatDescriptionGetExtension(
            format, extensionKey: kCMFormatDescriptionExtension_TransferFunction)
        guard let string = value as? String else { return .bt709 }
        // Compared as `String`: `CFString` pattern matching in a `switch` is
        // reference equality territory and not worth the risk.
        if string == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) { return .hlg }
        if string == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) { return .pq }
        return .bt709
    }

    private static func ycbcrMatrix(of format: CMFormatDescription,
                                    transfer: TransferFunction) -> YCbCrMatrix {
        let value = CMFormatDescriptionGetExtension(
            format, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix)
        guard let string = value as? String else {
            return transfer.isHDR ? .bt2020 : .bt709
        }
        if string == (kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4 as String) { return .bt601 }
        if string == (kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String) { return .bt2020 }
        return .bt709
    }

    /// QuickTime stores the creation date as either a `Date` or an ISO-8601
    /// string depending on how the file was written.
    private static func dateValue(of item: AVMetadataItem) -> Date? {
        if let date = item.value as? Date { return date }
        guard let string = item.stringValue else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private static func isProRes(_ subType: FourCharCode) -> Bool {
        // 'apcn', 'apcs', 'apco', 'apch', 'ap4h', 'ap4x'
        let prores: Set<FourCharCode> = [
            0x6170636E, 0x61706373, 0x6170636F, 0x61706368, 0x61703468, 0x61703478
        ]
        return prores.contains(subType)
    }
}
