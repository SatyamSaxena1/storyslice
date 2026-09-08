import CoreGraphics
import simd

/// How a source frame is fitted into the 9:16 output canvas.
enum FillMode: Int, CaseIterable {
    /// Aspect-fit foreground over a blurred, aspect-filled copy of itself.
    case blur = 0
    /// Aspect-fit foreground over solid black.
    case letterbox = 1
    /// Aspect-fill, cropping whatever overflows.
    case crop = 2

    var title: String {
        switch self {
        case .blur:      return "Blurred fill"
        case .letterbox: return "Letterbox"
        case .crop:      return "Crop to fill"
        }
    }
}

/// The per-frame sampling geometry, resolved once per export.
///
/// Both matrices map *output pixel* -> *source pixel*, which is the direction
/// the compute kernel needs: it walks output pixels and asks where to sample.
struct FrameGeometry: Equatable {
    /// Aspect-fit mapping. Used for the foreground in `.blur`/`.letterbox`.
    let outputToSourceFit: CGAffineTransform
    /// Aspect-fill mapping. Used for `.crop`, and for the blurred background.
    let outputToSourceCover: CGAffineTransform
    /// Source size after `preferredTransform` is applied — i.e. how the video
    /// is meant to be seen, not how its pixels are stored.
    let displaySize: CGSize
    /// True when the display aspect is at least as tall as the output, so an
    /// aspect-fit render leaves no bars and the background pass can be skipped.
    let fillsOutput: Bool

    /// Whether the blurred background pass needs to run at all.
    func needsBackground(for mode: FillMode) -> Bool {
        mode == .blur && !fillsOutput
    }
}

enum Geometry {

    static func frameGeometry(naturalSize: CGSize,
                              preferredTransform: CGAffineTransform,
                              outputSize: CGSize) -> FrameGeometry {

        let display = displaySize(naturalSize: naturalSize,
                                  preferredTransform: preferredTransform)

        // Degenerate input: fall back to identity rather than dividing by zero.
        guard display.width > 0, display.height > 0,
              outputSize.width > 0, outputSize.height > 0 else {
            return FrameGeometry(outputToSourceFit: .identity,
                                 outputToSourceCover: .identity,
                                 displaySize: display,
                                 fillsOutput: true)
        }

        let sx = outputSize.width / display.width
        let sy = outputSize.height / display.height
        let displayToSource = preferredTransform.inverted()

        func matrix(scale: CGFloat) -> CGAffineTransform {
            // output px -> centred, unscaled display px -> source px
            var m = CGAffineTransform(translationX: -outputSize.width / 2,
                                      y: -outputSize.height / 2)
            m = m.concatenating(CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
            m = m.concatenating(CGAffineTransform(translationX: display.width / 2,
                                                  y: display.height / 2))
            return m.concatenating(displayToSource)
        }

        return FrameGeometry(
            outputToSourceFit: matrix(scale: min(sx, sy)),
            outputToSourceCover: matrix(scale: max(sx, sy)),
            displaySize: display,
            // Within half a pixel counts as filling — avoids a pointless blur
            // pass on footage that is 1079x1920.
            fillsOutput: display.height / display.width
                >= outputSize.height / outputSize.width - 0.001)
    }

    /// `naturalSize` rotated/flipped by `preferredTransform`, as a positive size.
    static func displaySize(naturalSize: CGSize,
                            preferredTransform t: CGAffineTransform) -> CGSize {
        CGSize(width: abs(naturalSize.width * t.a + naturalSize.height * t.c),
               height: abs(naturalSize.width * t.b + naturalSize.height * t.d))
    }
}

extension CGAffineTransform {
    /// Column-major 3x3 for Metal. `(x, y) -> (ax + cy + tx, bx + dy + ty)`.
    var simd3x3: simd_float3x3 {
        simd_float3x3(columns: (
            SIMD3<Float>(Float(a),  Float(b),  0),
            SIMD3<Float>(Float(c),  Float(d),  0),
            SIMD3<Float>(Float(tx), Float(ty), 1)))
    }
}
