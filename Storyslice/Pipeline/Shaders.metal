#include <metal_stdlib>
using namespace metal;

// Kept byte-compatible with the Swift mirrors in MetalRenderer.swift.
// If you change a field here, change it there.

struct ConvertUniforms {
    float3x3 ycbcrToRGB;    // full-range Y'CbCr (Cb/Cr already centred) -> R'G'B'
    float3x3 gamutToRec709; // source primaries -> BT.709 (identity for SDR)
    float    yOffset;       // 16/255 video range, 0 full range
    float    yScale;        // 255/219 video range, 1 full range
    float    cScale;        // 255/224 video range, 1 full range
    uint     transfer;      // 0 = BT.709, 1 = HLG, 2 = PQ
    float    peakNits;      // display-referred peak of the source (HDR only)
};

struct CompositeUniforms {
    float3x3 outputToSource; // output px -> source px
    float2   sourceSize;     // px
    uint     hasBackground;  // 0 = black behind bars, 1 = sample bgTex
};

struct ResampleUniforms {
    float3x3 outputToSource;
    float2   sourceSize;
    float2   dstSize;
};

constexpr sampler linearSampler(coord::normalized,
                                address::clamp_to_edge,
                                filter::linear);

// ---------------------------------------------------------------------------
// Transfer functions
// ---------------------------------------------------------------------------

static inline float3 eotf709(float3 v) {
    // Inverse of the BT.709 OETF.
    float3 lo = v / 4.5;
    float3 hi = pow(max((v + 0.099) / 1.099, 0.0), 1.0 / 0.45);
    return select(hi, lo, v < 0.081);
}

static inline float3 oetf709(float3 l) {
    l = clamp(l, 0.0, 1.0);
    float3 lo = l * 4.5;
    float3 hi = 1.099 * pow(l, 0.45) - 0.099;
    return select(hi, lo, l < 0.018);
}

static inline float3 eotfHLG(float3 v) {
    // ARIB STD-B67 inverse OETF -> scene linear in [0, 12].
    const float a = 0.17883277, b = 0.28466892, c = 0.55991073;
    float3 lo = (v * v) / 3.0;
    float3 hi = (exp((v - c) / a) + b) / 12.0;
    return select(hi, lo, v <= 0.5);
}

static inline float3 eotfPQ(float3 v) {
    // SMPTE ST 2084 -> luminance normalised so 1.0 == 10,000 nits.
    const float m1 = 0.1593017578125, m2 = 78.84375;
    const float c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
    float3 p = pow(max(v, 0.0), 1.0 / m2);
    return pow(max(p - c1, 0.0) / max(c2 - c3 * p, 1e-6), 1.0 / m1);
}

// ponytail: extended Reinhard, not the full BT.2390 EETF. It holds mid-tone
// appearance and rolls off highlights, which is what stops HDR exports
// reading grey. Swap in BT.2390 with a real knee if the roll-off looks flat
// on graded footage.
static inline float3 toneMapToSDR(float3 linearRGB, float peakRelative) {
    float peak = max(peakRelative, 1.0);
    float3 v = max(linearRGB, 0.0);
    return (v * (1.0 + v / (peak * peak))) / (1.0 + v);
}

// ---------------------------------------------------------------------------
// Pass 1 - decode Y'CbCr to display-referred BT.709 RGB, once per frame.
// ---------------------------------------------------------------------------

kernel void convertYCbCr(texture2d<float, access::read>   luma   [[texture(0)]],
                         texture2d<float, access::sample> chroma [[texture(1)]],
                         texture2d<float, access::write>  dst    [[texture(2)]],
                         constant ConvertUniforms&        u      [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }

    float y = (luma.read(gid).r - u.yOffset) * u.yScale;
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
    float2 cbcr = (chroma.sample(linearSampler, uv).rg - 0.5) * u.cScale;

    float3 rgbPrime = u.ycbcrToRGB * float3(y, cbcr.x, cbcr.y);

    float3 linearRGB;
    switch (u.transfer) {
        case 1:
            // HLG scene light, nominal white at 1.0 after the /12 normalisation.
            linearRGB = eotfHLG(clamp(rgbPrime, 0.0, 1.0)) * 12.0;
            linearRGB = toneMapToSDR(linearRGB, u.peakNits / 100.0);
            break;
        case 2:
            // PQ absolute luminance, rescaled so 100 nits == 1.0 (SDR white).
            linearRGB = eotfPQ(clamp(rgbPrime, 0.0, 1.0)) * 100.0;
            linearRGB = toneMapToSDR(linearRGB, u.peakNits / 100.0);
            break;
        default:
            linearRGB = eotf709(rgbPrime);
            break;
    }

    linearRGB = u.gamutToRec709 * linearRGB;
    dst.write(float4(oetf709(linearRGB), 1.0), gid);
}

// ---------------------------------------------------------------------------
// Pass 2 - aspect-fill downscale into the small background texture.
// ---------------------------------------------------------------------------

kernel void resampleCover(texture2d<float, access::sample> src [[texture(0)]],
                          texture2d<float, access::write>  dst [[texture(1)]],
                          constant ResampleUniforms&       u   [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }

    // The background texture is a scaled-down stand-in for the output canvas,
    // so map this pixel back up to canvas space before applying the matrix.
    float2 scale = u.dstSize / float2(dst.get_width(), dst.get_height());
    float2 outPx = (float2(gid) + 0.5) * scale;
    float3 p = u.outputToSource * float3(outPx, 1.0);
    float2 uv = clamp(p.xy / u.sourceSize, 0.0, 1.0);
    dst.write(float4(src.sample(linearSampler, uv).rgb, 1.0), gid);
}

// ---------------------------------------------------------------------------
// Pass 3 - dual-Kawase blur. Cheap, and visually indistinguishable from a
// wide Gaussian at this radius.
// ---------------------------------------------------------------------------

kernel void kawaseDown(texture2d<float, access::sample> src [[texture(0)]],
                       texture2d<float, access::write>  dst [[texture(1)]],
                       uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float2 h = 1.0 / float2(src.get_width(), src.get_height());
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());

    float3 sum = src.sample(linearSampler, uv).rgb * 4.0;
    sum += src.sample(linearSampler, uv + float2(-h.x, -h.y)).rgb;
    sum += src.sample(linearSampler, uv + float2( h.x, -h.y)).rgb;
    sum += src.sample(linearSampler, uv + float2(-h.x,  h.y)).rgb;
    sum += src.sample(linearSampler, uv + float2( h.x,  h.y)).rgb;
    dst.write(float4(sum / 8.0, 1.0), gid);
}

kernel void kawaseUp(texture2d<float, access::sample> src [[texture(0)]],
                     texture2d<float, access::write>  dst [[texture(1)]],
                     uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float2 h = 1.0 / float2(src.get_width(), src.get_height());
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());

    float3 sum = src.sample(linearSampler, uv + float2(-h.x * 2.0, 0.0)).rgb;
    sum += src.sample(linearSampler, uv + float2(-h.x,  h.y)).rgb * 2.0;
    sum += src.sample(linearSampler, uv + float2( 0.0,  h.y * 2.0)).rgb;
    sum += src.sample(linearSampler, uv + float2( h.x,  h.y)).rgb * 2.0;
    sum += src.sample(linearSampler, uv + float2( h.x * 2.0, 0.0)).rgb;
    sum += src.sample(linearSampler, uv + float2( h.x, -h.y)).rgb * 2.0;
    sum += src.sample(linearSampler, uv + float2( 0.0, -h.y * 2.0)).rgb;
    sum += src.sample(linearSampler, uv + float2(-h.x, -h.y)).rgb * 2.0;
    dst.write(float4(sum / 12.0, 1.0), gid);
}

// ---------------------------------------------------------------------------
// Pass 4 - composite foreground over background into the writer's buffer.
// ---------------------------------------------------------------------------

kernel void composite(texture2d<float, access::sample> src [[texture(0)]],
                      texture2d<float, access::sample> bg  [[texture(1)]],
                      texture2d<float, access::write>  dst [[texture(2)]],
                      constant CompositeUniforms&      u   [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) { return; }

    float2 uvOut = (float2(gid) + 0.5) / float2(w, h);
    float3 background = u.hasBackground != 0
        ? bg.sample(linearSampler, uvOut).rgb
        : float3(0.0);

    float3 p = u.outputToSource * float3(float2(gid) + 0.5, 1.0);
    float2 srcPx = p.xy;

    // Explicit bounds test: clamp_to_edge would smear edge pixels across the
    // letterbox bars instead of leaving them to the background.
    bool inside = all(srcPx >= 0.0) && all(srcPx < u.sourceSize);
    float3 colour = inside
        ? src.sample(linearSampler, srcPx / u.sourceSize).rgb
        : background;

    dst.write(float4(colour, 1.0), gid);
}
