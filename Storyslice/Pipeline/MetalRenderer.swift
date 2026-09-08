import AVFoundation
import CoreVideo
import Metal
import simd

// Mirrors of the structs in Shaders.metal. Layout must stay identical:
// `simd_float3x3` is three 16-byte-aligned columns in both languages.
private struct ConvertUniforms {
    var ycbcrToRGB: simd_float3x3
    var gamutToRec709: simd_float3x3
    var yOffset: Float
    var yScale: Float
    var cScale: Float
    var transfer: UInt32
    var peakNits: Float
}

private struct CompositeUniforms {
    var outputToSource: simd_float3x3
    var sourceSize: SIMD2<Float>
    var hasBackground: UInt32
}

private struct ResampleUniforms {
    var outputToSource: simd_float3x3
    var sourceSize: SIMD2<Float>
    var dstSize: SIMD2<Float>
}

enum RenderError: LocalizedError {
    case noDevice
    case libraryMissing
    case textureCreationFailed
    case commandBufferFailed(String)

    var errorDescription: String? {
        switch self {
        case .noDevice: return "This device has no Metal GPU."
        case .libraryMissing: return "The Metal shader library failed to load."
        case .textureCreationFailed: return "A video frame could not be bound to the GPU."
        case .commandBufferFailed(let why): return "GPU render failed: \(why)"
        }
    }
}

/// Converts, transforms and composites one frame per call, entirely on the GPU.
///
/// Input and output `CVPixelBuffer`s are bound through `CVMetalTextureCache`,
/// so no frame data is ever copied to the CPU.
final class MetalRenderer {

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let convertPSO: MTLComputePipelineState
    private let resamplePSO: MTLComputePipelineState
    private let downPSO: MTLComputePipelineState
    private let upPSO: MTLComputePipelineState
    private let compositePSO: MTLComputePipelineState
    private var textureCache: CVMetalTextureCache!

    private let outputSize: CGSize
    private let fillMode: FillMode
    private let geometry: FrameGeometry
    private let source: VideoSourceInfo
    private let wantsBackground: Bool

    /// Allocated on the first frame, when the real buffer dimensions are known.
    private var converted: MTLTexture?
    private var blurChain: [MTLTexture] = []
    private var bufferSize: CGSize = .zero
    private var fitMatrix = matrix_identity_float3x3
    private var coverMatrix = matrix_identity_float3x3

    private static let threadgroup = MTLSize(width: 16, height: 16, depth: 1)

    init(source: VideoSourceInfo,
         outputSize: CGSize,
         fillMode: FillMode) throws {

        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { throw RenderError.noDevice }
        guard let library = device.makeDefaultLibrary() else { throw RenderError.libraryMissing }

        func pso(_ name: String) throws -> MTLComputePipelineState {
            guard let fn = library.makeFunction(name: name) else { throw RenderError.libraryMissing }
            return try device.makeComputePipelineState(function: fn)
        }

        self.device = device
        self.queue = queue
        self.convertPSO = try pso("convertYCbCr")
        self.resamplePSO = try pso("resampleCover")
        self.downPSO = try pso("kawaseDown")
        self.upPSO = try pso("kawaseUp")
        self.compositePSO = try pso("composite")

        self.outputSize = outputSize
        self.fillMode = fillMode
        self.source = source
        self.geometry = Geometry.frameGeometry(naturalSize: source.naturalSize,
                                               preferredTransform: source.preferredTransform,
                                               outputSize: outputSize)
        self.wantsBackground = geometry.needsBackground(for: fillMode)

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache = cache else { throw RenderError.textureCreationFailed }
        self.textureCache = cache
    }

    // MARK: - Per-frame

    func render(source pixelBuffer: CVPixelBuffer, into destination: CVPixelBuffer) throws {
        try prepareIntermediates(for: pixelBuffer)

        let tenBit = source.isTenBit
        var held: [CVMetalTexture] = []

        guard let luma = makeTexture(pixelBuffer, plane: 0,
                                     format: tenBit ? .r16Unorm : .r8Unorm, held: &held),
              let chroma = makeTexture(pixelBuffer, plane: 1,
                                       format: tenBit ? .rg16Unorm : .rg8Unorm, held: &held),
              let output = makeTexture(destination, plane: 0,
                                       format: .bgra8Unorm, held: &held),
              let converted = converted,
              let commands = queue.makeCommandBuffer()
        else { throw RenderError.textureCreationFailed }

        // Pass 1 - YCbCr to display-referred BT.709.
        var convertUniforms = makeConvertUniforms()
        encode(convertPSO, into: commands,
               textures: [luma, chroma, converted],
               bytes: &convertUniforms, length: MemoryLayout<ConvertUniforms>.stride,
               width: converted.width, height: converted.height)

        // Passes 2-3 - the blurred background, only when bars would show.
        if wantsBackground, let base = blurChain.first {
            var resampleUniforms = ResampleUniforms(
                outputToSource: coverMatrix,
                sourceSize: SIMD2(Float(bufferSize.width), Float(bufferSize.height)),
                dstSize: SIMD2(Float(outputSize.width), Float(outputSize.height)))
            encode(resamplePSO, into: commands,
                   textures: [converted, base],
                   bytes: &resampleUniforms, length: MemoryLayout<ResampleUniforms>.stride,
                   width: base.width, height: base.height)

            // chain = [bg0, bg1, bg2, up1, up0]
            encodeBlur(downPSO, from: blurChain[0], to: blurChain[1], into: commands)
            encodeBlur(downPSO, from: blurChain[1], to: blurChain[2], into: commands)
            encodeBlur(upPSO,   from: blurChain[2], to: blurChain[3], into: commands)
            encodeBlur(upPSO,   from: blurChain[3], to: blurChain[4], into: commands)
        }

        // Pass 4 - composite into the writer buffer.
        var compositeUniforms = CompositeUniforms(
            outputToSource: fillMode == .crop ? coverMatrix : fitMatrix,
            sourceSize: SIMD2(Float(bufferSize.width), Float(bufferSize.height)),
            hasBackground: wantsBackground ? 1 : 0)
        // A texture must be bound even when unused; the shader ignores it.
        let background = wantsBackground ? blurChain[4] : converted
        encode(compositePSO, into: commands,
               textures: [converted, background, output],
               bytes: &compositeUniforms, length: MemoryLayout<CompositeUniforms>.stride,
               width: output.width, height: output.height)

        commands.commit()
        // ponytail: synchronous wait rather than a triple-buffered pipeline.
        // The hardware encoder, not the GPU, is the bottleneck at 1080p.
        // Add a 3-deep semaphore if throughput ever needs it. The wait is also
        // what keeps the CVMetalTexture handles alive for the whole dispatch.
        commands.waitUntilCompleted()
        withExtendedLifetime(held) {}

        if let error = commands.error {
            throw RenderError.commandBufferFailed(error.localizedDescription)
        }
    }

    // MARK: - Setup

    private func prepareIntermediates(for pixelBuffer: CVPixelBuffer) throws {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let size = CGSize(width: width, height: height)
        guard size != bufferSize else { return }
        bufferSize = size

        // The geometry was solved against `naturalSize`; decoded buffers can be
        // padded or clean-aperture-cropped, so rescale into buffer space.
        let sx = source.naturalSize.width > 0 ? size.width / source.naturalSize.width : 1
        let sy = source.naturalSize.height > 0 ? size.height / source.naturalSize.height : 1
        let toBuffer = CGAffineTransform(scaleX: sx, y: sy)
        fitMatrix = geometry.outputToSourceFit.concatenating(toBuffer).simd3x3
        coverMatrix = geometry.outputToSourceCover.concatenating(toBuffer).simd3x3

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        converted = device.makeTexture(descriptor: descriptor)

        blurChain = []
        if wantsBackground {
            for divisor in [4, 8, 16, 8, 4] {
                let d = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .rgba16Float,
                    width: max(Int(outputSize.width) / divisor, 1),
                    height: max(Int(outputSize.height) / divisor, 1),
                    mipmapped: false)
                d.usage = [.shaderRead, .shaderWrite]
                d.storageMode = .private
                guard let texture = device.makeTexture(descriptor: d) else {
                    throw RenderError.textureCreationFailed
                }
                blurChain.append(texture)
            }
        }
        if converted == nil { throw RenderError.textureCreationFailed }
    }

    private func makeConvertUniforms() -> ConvertUniforms {
        let c = source.matrix.coefficients
        let ycbcr = simd_float3x3(columns: (
            SIMD3(c.r.0, c.g.0, c.b.0),
            SIMD3(c.r.1, c.g.1, c.b.1),
            SIMD3(c.r.2, c.g.2, c.b.2)))

        // BT.2020 -> BT.709, linear light. BT.601 primaries differ from 709 by
        // less than a JND on phone footage, so they share the identity path.
        let gamut = source.matrix == .bt2020
            ? simd_float3x3(columns: (SIMD3( 1.6605, -0.1246, -0.0182),
                                      SIMD3(-0.5876,  1.1329, -0.1006),
                                      SIMD3(-0.0728, -0.0083,  1.1187)))
            : matrix_identity_float3x3

        // `readerPixelFormat` always requests the `...VideoRange` pixel format
        // (never `...FullRange`), so the decoded buffer is video-range 16-235
        // regardless of what the source bitstream was tagged as — there is no
        // full-range case to branch on here.
        // 10-bit biplanar samples are left-aligned in 16-bit words, so reading
        // them as `r16Unorm` already yields ~code/1023.
        // Split into a plain if/else, not a ternary-of-tuples: Swift's type
        // checker times out on that shape ("unable to type-check this
        // expression in reasonable time") once literal division is involved.
        let offset: Float
        let yScale: Float
        let cScale: Float
        if source.isTenBit {
            offset = 64.0 / 1023
            yScale = 1023.0 / 876
            cScale = 1023.0 / 896
        } else {
            offset = 16.0 / 255
            yScale = 255.0 / 219
            cScale = 255.0 / 224
        }

        return ConvertUniforms(
            ycbcrToRGB: ycbcr,
            gamutToRec709: gamut,
            yOffset: offset,
            yScale: yScale,
            cScale: cScale,
            transfer: source.transfer.rawValue,
            // iPhone HDR capture masters to 1000 nits for both HLG and
            // Dolby Vision 8.4.
            peakNits: source.transfer.isHDR ? 1000 : 100)
    }

    // MARK: - Plumbing

    private func makeTexture(_ buffer: CVPixelBuffer,
                             plane: Int,
                             format: MTLPixelFormat,
                             held: inout [CVMetalTexture]) -> MTLTexture? {
        let planar = CVPixelBufferIsPlanar(buffer)
        let width = planar ? CVPixelBufferGetWidthOfPlane(buffer, plane)
                           : CVPixelBufferGetWidth(buffer)
        let height = planar ? CVPixelBufferGetHeightOfPlane(buffer, plane)
                            : CVPixelBufferGetHeight(buffer)

        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, buffer, nil,
            format, width, height, plane, &texture)
        guard status == kCVReturnSuccess, let texture = texture else { return nil }
        held.append(texture)
        return CVMetalTextureGetTexture(texture)
    }

    private func encode(_ pipeline: MTLComputePipelineState,
                        into commands: MTLCommandBuffer,
                        textures: [MTLTexture],
                        bytes: UnsafeRawPointer,
                        length: Int,
                        width: Int,
                        height: Int) {
        guard let encoder = commands.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(pipeline)
        for (index, texture) in textures.enumerated() {
            encoder.setTexture(texture, index: index)
        }
        encoder.setBytes(bytes, length: length, index: 0)
        dispatch(encoder, width: width, height: height)
        encoder.endEncoding()
    }

    private func encodeBlur(_ pipeline: MTLComputePipelineState,
                            from src: MTLTexture,
                            to dst: MTLTexture,
                            into commands: MTLCommandBuffer) {
        guard let encoder = commands.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(src, index: 0)
        encoder.setTexture(dst, index: 1)
        dispatch(encoder, width: dst.width, height: dst.height)
        encoder.endEncoding()
    }

    /// Uniform threadgroups plus in-kernel bounds checks: non-uniform dispatch
    /// needs an A11, and iOS 13 reaches back to the A9.
    private func dispatch(_ encoder: MTLComputeCommandEncoder, width: Int, height: Int) {
        let tg = Self.threadgroup
        encoder.dispatchThreadgroups(
            MTLSize(width: (width + tg.width - 1) / tg.width,
                    height: (height + tg.height - 1) / tg.height,
                    depth: 1),
            threadsPerThreadgroup: tg)
    }
}

