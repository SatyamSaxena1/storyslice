# Storyslice

Splits a video into ordered, 1080x1920 Instagram-Story-ready segments. iOS 13.0+.

The interesting part is the export pipeline, not the app. One `AVAssetReader`
pass feeds a Metal compute chain (colour conversion, HDR tone mapping, rotation,
blurred-fill compositing) which writes straight into the encoder's pixel buffer
pool, switching `AVAssetWriter`s at each planned cut. No frame data touches the
CPU; the source is decoded exactly once no matter how many segments come out.

The UI is four plain UIKit view controllers on purpose.

## Build

No Mac needed: `.github/workflows/build.yml` runs on a hosted macOS runner and
produces `Storyslice.ipa` / `Storyslice.tipa` (ad-hoc signed, `Info.plist`
intact) as a `Storyslice-trollstore` artifact on every push to `main` or via
**Run workflow**.

On a Mac, the project file is generated:

```bash
brew install xcodegen && xcodegen generate && open Storyslice.xcodeproj
```

Signing is off by default (`CODE_SIGNING_ALLOWED=NO`); set a team in **Signing &
Capabilities** if you want to run it on a device the normal way.

## Test

```bash
xcodebuild test -project Storyslice.xcodeproj -scheme Storyslice -destination 'platform=iOS Simulator,name=iPhone 17'
```

- `SegmentPlanTests`, `TransformTests` — pure math, no GPU, no media.
- `PipelineIntegrationTests` — builds synthetic source movies at runtime and
  round-trips them through the real pipeline. Needs a Metal device: a physical
  iPhone or an Apple-silicon simulator.

## Install via TrollStore (recommended)

Download the `Storyslice-trollstore` artifact from the latest green run, open
`Storyslice.tipa` (or `.ipa`) in **TrollStore** on the device, tap **Install**.

That's it. TrollStore's CoreTrust bypass installs the ad-hoc build permanently:
`Info.plist` is preserved verbatim (so the two `NSPhotoLibrary*UsageDescription`
strings survive and Photos access works on first save), the real bundle id
`com.satyamsaxena.storyslice` is kept, and there is no expiry and no "Trust this
developer" step. The CI `codesign -s -` step gives the bundle a real ad-hoc
`_CodeSignature`, which is the smoothest input for TrollStore's *Ad-Hoc Signed*
install path; the fully unsigned zip also installs on TrollStore 2.x if that
step is ever skipped.

`Storyslice.entitlements` (ad-hoc signed in during CI, honoured by TrollStore)
carries only `com.apple.developer.kernel.increased-memory-limit` (raises the
jetsam ceiling for the 4K/HDR Metal pipeline) and `get-task-allow` (debugger
attach). If either ever blocks launch, empty the dict and rebuild.

## Alternative: ReProvision (free-account resigning)

If you don't have TrollStore, a free Apple ID + **ReProvision** works, via a
rootless jailbreak's Filza → Open In → ReProvision Again → Install flow. Two
gotchas specific to this path:

1. **Trust the developer cert once, per rotation.** A freshly-signed app
   silently fails to launch (no crash log, just bounces back to the home
   screen) until **Settings → General → VPN & Device Management → [the Apple
   Development profile] → Trust**. Free-tier certs expire in ~7 days, so this
   repeats on each rotation.
2. **ReProvision regenerates `Info.plist` from scratch**, discarding every
   custom key the CI build produced -- including
   `NSPhotoLibraryUsageDescription` / `NSPhotoLibraryAddUsageDescription`.
   Without them the first Photos access call TCC-kills the app (not a catchable
   exception). Run `scripts/patch-privacy-plist.sh` as root on the device after
   every re-sign to merge them back into the installed bundle in place; no
   re-signing needed afterward on a jailbreak that doesn't enforce
   resource-hash validation. **TrollStore does not have this problem** -- the
   script is for this path only.

Symptoms both ReProvision gotchas produce -- silent launch failure with zero
diagnostics, or a crash that looks like a sandbox/file-race bug -- are covered
in more depth in code comments near `LibraryWriter` and `PhotosCompat`.

## Layout

| Path | |
|---|---|
| `Pipeline/SegmentPlan.swift` | Duration -> cut ranges. Integer math in the source timescale so segments sum exactly. |
| `Pipeline/Transform.swift` | `preferredTransform` x fill mode -> output-pixel-to-source-pixel matrix. |
| `Pipeline/AssetLoader.swift` | Reads colour, transfer function, bit depth and rotation off the format description. |
| `Pipeline/MetalRenderer.swift` | Texture caches, pipeline states, per-frame dispatch. |
| `Pipeline/Shaders.metal` | Convert / resample / dual-Kawase blur / composite. |
| `Pipeline/VideoSlicer.swift` | The single-pass reader-to-N-writers orchestrator. |
| `Pipeline/LibraryWriter.swift` | Photos album, with the creation-date stamping that keeps segments in posting order. |
| `Compat/` | `PhotosCompat` is the only file containing `#available`; `AVCompat` wraps the pre-iOS-16 async loading API. |

## Known ceilings

Grep `ponytail:` for the deliberate shortcuts and their upgrade paths. Briefly:

- Tone mapping is extended Reinhard, not the full BT.2390 EETF.
- Frames render synchronously (`waitUntilCompleted`) rather than pipelined.
- Writer readiness is polled at 4 ms rather than driven by `requestMediaDataWhenReady`.
- 10-bit is inferred from HDR/ProRes rather than parsed from the sample description.

## Notes on two premises

- Instagram Stories accept 60-second segments now, not 15, so segment length is
  a setting and defaults to 60. The durable value is the 9:16 conversion plus
  splitting anything longer.
- Swift concurrency back-deploys to iOS 13.0, so the whole pipeline is
  `async`/`await`. The real cost of the iOS 13 floor is SwiftUI, which is why
  the UI is UIKit.
