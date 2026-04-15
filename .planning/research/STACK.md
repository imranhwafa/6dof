# Stack Research

**Domain:** Native macOS XR virtual desktop (Viture Luma Ultra)
**Researched:** 2026-04-14
**Confidence:** MEDIUM — Core Apple APIs verified via official docs and WWDC sessions (HIGH). Viture macOS SDK researched via official docs page (MEDIUM — no public GitHub, no SPM package; C API confirmed, Swift wrapper not confirmed). Stereo rendering patterns verified via Apple Metal docs and community implementations (MEDIUM).

---

## Recommended Stack

### Core Technologies

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| Swift | 5.10 / Xcode 16 (Swift 6 opt-in) | Primary language | Only language choice for native macOS app. Swift 6 strict concurrency is available but optional — enable only when ready. Objective-C is unnecessary overhead for a greenfield project. |
| Metal | (ships with macOS 13+, no version pin) | GPU rendering pipeline | The only correct choice for direct stereo quad rendering with full viewport control. SceneKit and RealityKit both insert framework assumptions that break a hand-rolled stereo pipeline. Metal gives you raw `MTLRenderCommandEncoder` control. |
| MetalKit (`MTKView`) | (ships with macOS 13+) | Display surface and render loop | `MTKView` manages the `CAMetalLayer`, swap chain, and `CVDisplayLink`-driven render loop. Writing this manually provides no benefit. Use `MTKView` as the NSView backing the stereo output window. |
| ScreenCaptureKit | macOS 12.3+ (full control: 13+) | Live window/screen capture | The modern, Apple-recommended API replacing `CGWindowListCreateImage` and `CGDisplayStream`. Per-window filtering, low-latency IOSurface-backed output, async frame delivery. Target macOS 13 for `SCStreamConfiguration` full properties. |
| AppKit (NSApplication, NSWindow, NSScreen) | macOS 13+ | App lifecycle, window management, display detection | Required to identify which NSScreen is the Viture display (via `CGDirectDisplayID`), create a borderless fullscreen window on it, and host the `MTKView`. No SwiftUI needed — this is a rendering-first app, not a form UI. |

### Supporting Libraries / Frameworks

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| simd (Swift/simd module) | stdlib | Matrix math, quaternion math | Use `simd_float4x4` for view/projection matrices and `simd_quatf` for quaternion-to-rotation-matrix conversion from Viture pose data. No third-party math library needed — Apple's simd module is zero-overhead and ships with the SDK. |
| CoreVideo (`CVPixelBuffer`, `CVMetalTextureCache`) | macOS 13+ | Zero-copy IOSurface → Metal texture path | `CVMetalTextureCacheCreateTextureFromImage` turns a `CMSampleBuffer` from ScreenCaptureKit into a `MTLTexture` without a CPU copy. Required to hit 60fps without stalling on texture uploads. Must set `kCVPixelBufferMetalCompatibilityKey = true` in `SCStreamConfiguration`. |
| CoreMedia (`CMSampleBuffer`) | macOS 13+ | Frame delivery from ScreenCaptureKit | ScreenCaptureKit delivers frames as `CMSampleBuffer`; the pixel buffer inside is IOSurface-backed. Consumed only to extract the `CVPixelBuffer`. |
| Viture XR Glasses SDK (`libglasses` / C API) | Latest (check developer.viture.com) | Head pose quaternion delivery | The only source of head orientation data from the Luma Ultra on macOS. C API bridged to Swift via a bridging header or module map. See "Viture SDK Integration" section below. |

### Development Tools

| Tool | Purpose | Notes |
|------|---------|-------|
| Xcode 16 | Build system, Metal shader compilation, debugger | Required. Metal shaders (`.metal` files) are compiled at build time by Xcode's `metallib` toolchain. Do not try to use external compilers for Metal shaders. |
| Instruments (Metal System Trace) | GPU frame timing, pipeline stall detection | Essential for diagnosing stereo rendering frame budget issues. Open early — don't wait until performance is broken. |
| Instruments (Screen Recording Activity) | ScreenCaptureKit frame latency profiling | Use to verify IOSurface path is active and measure end-to-end capture latency. |
| Metal Debugger (GPU Frame Capture) | Shader inspection, texture verification, viewport debugging | Use to confirm left/right viewport split is correct and textures contain live window content. |
| `xr_device_provider_*` C headers | Viture SDK API surface | Downloaded from developer.viture.com. No CocoaPods, no SPM. Manual integration only — see below. |

---

## Viture SDK Integration

**Confidence: MEDIUM** — Verified via official Viture SDK documentation page. No public GitHub. No Swift wrapper shipped by Viture.

### What the SDK Provides

The Viture XR Glasses SDK is a native C/C++ library (`libglasses`), distributed as a binary + headers. It supports macOS (arm64, Sequoia+). There is no Swift Package Manager support, no CocoaPods spec, and no official Swift wrapper.

**Head pose data formats:**

- **Luma Ultra (Carina device — polling API):**
  ```c
  xr_device_provider_get_gl_pose_carina(handle, pose, predict_time, &pose_status);
  // Returns 7 floats: [px, py, pz, qw, qx, qy, qz]
  // Position + quaternion in OpenGL coordinate convention
  ```

- **Gen1/Gen2 devices (callback API):**
  ```c
  xr_device_provider_register_imu_pose_callback(handle, ImuPoseCallback);
  // Callback delivers: [roll, pitch, yaw, qw, qx, qy, qz]
  // Euler angles + quaternion
  ```

For the Luma Ultra specifically, use the polling API in your render loop. The 7-float pose `[px, py, pz, qw, qx, qy, qz]` gives you both rotation (quaternion) and position (for future 6DOF use). In v1, you consume only `qw, qx, qy, qz`.

**Device detection:** The SDK opens the USB device automatically by VID/PID (`0x35CA`). No manual device enumeration needed on macOS.

### Swift Bridging Pattern

Since Viture ships a C API, use a bridging header in your Xcode target:

```
// VitureSDK-Bridging-Header.h
#include "xr_device_provider.h"
```

Set `SWIFT_OBJC_BRIDGING_HEADER` to this file in build settings. The C functions become callable directly from Swift. Wrap them in a Swift `class VitureTracker` actor or class so the unsafe C calls are isolated from the rest of the codebase.

**Do not** attempt to use Swift Package Manager binary targets for this library — `binaryTarget` requires `.xcframework` format, which Viture does not ship. Link the `.dylib` manually in Xcode's "Link Binary With Libraries" and set `LD_RUNPATH_SEARCH_PATHS` to `@loader_path/../Frameworks` or embed the dylib in the app bundle.

---

## ScreenCaptureKit API Surface

**Confidence: HIGH** — Verified via Apple WWDC22/23/24 sessions and Apple Developer Documentation.

### Minimum Required Classes

```
SCShareableContent       — enumerate displays, windows, apps
SCContentFilter          — specify what to capture (single window, display, app)
SCStreamConfiguration    — configure output format, resolution, framerate
SCStream                 — manage the capture session
SCStreamOutput (protocol) — receive CMSampleBuffer frames
```

### Key Configuration Properties (SCStreamConfiguration)

```swift
let config = SCStreamConfiguration()
config.width = window.frame.width * scaleFactor   // match source window resolution
config.height = window.frame.height * scaleFactor
config.minimumFrameInterval = CMTime(value: 1, timescale: 60)  // 60fps cap
config.pixelFormat = kCVPixelFormatType_32BGRA    // BGRA — matches Metal BGRA8Unorm texture format
config.colorSpaceName = CGColorSpace.sRGB
config.showsCursor = false
// Critical for zero-copy Metal path:
config.pixelFormat = kCVPixelFormatType_32BGRA
// Set on the pixel buffer attributes to enable CVMetalTextureCache:
// kCVPixelBufferMetalCompatibilityKey = true (set via SCStreamConfiguration.pixelFormat)
```

**macOS version notes:**
- macOS 12.3: `SCStream` introduced
- macOS 13: `SCStreamConfiguration` gains full control; per-window `SCContentFilter` stable
- macOS 14: `SCContentSharingPicker` (system picker UI), `SCScreenshotManager`, HDR properties
- macOS 15: HDR capture via `captureDynamicRange`, microphone capture

Target macOS 13 as minimum. `SCContentSharingPicker` (macOS 14) can be used for the window-selection UX but is not required.

### Frame Delivery Pattern

```swift
// SCStreamOutput delegate method — called on a background thread
func stream(_ stream: SCStream,
            didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
            of type: SCStreamOutputType) {
    guard type == .screen else { return }
    guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
    // Hand off to renderer — do NOT process on this thread
    renderer.updateTexture(from: pixelBuffer)
}
```

Frame processing must be non-blocking — hand the `CVPixelBuffer` to your render layer immediately and return.

---

## Metal Stereo Pipeline

**Confidence: HIGH** — Verified via Apple Metal documentation, WWDC sessions, and community implementations.

### Architecture

The Viture Luma Ultra presents to macOS as an external display at **3840×1080** (side-by-side stereo: 1920×1080 per eye). Your `MTKView` occupies a fullscreen `NSWindow` on that `NSScreen`. The render loop draws two viewports per frame — left eye at `x=0`, right eye at `x=1920`.

### MTKView Setup

```swift
// Identify the Viture display
let vitureScreen = NSScreen.screens.first { screen in
    // Viture appears at 3840x1080; filter by resolution or device name
    screen.frame.width == 3840 && screen.frame.height == 1080
}!

let window = NSWindow(contentRect: vitureScreen.frame, ...)
window.setFrame(vitureScreen.frame, display: true)
let mtkView = MTKView(frame: vitureScreen.frame, device: MTLCreateSystemDefaultDevice())
mtkView.colorPixelFormat = .bgra8Unorm
mtkView.depthStencilPixelFormat = .depth32Float
mtkView.preferredFramesPerSecond = 60
```

### Viewport Splitting

```metal
// Vertex shader — amplify single geometry for both eyes
vertex VertexOut vertexShader(
    uint vertexID     [[vertex_id]],
    uint viewportID   [[viewport_array_index]],
    constant Uniforms &uniforms [[buffer(0)]]
) {
    float4x4 viewProj = (viewportID == 0) 
        ? uniforms.leftViewProjection 
        : uniforms.rightViewProjection;
    // ... transform vertex
}
```

```swift
// Render pass setup — two viewports, single draw call
let leftViewport  = MTLViewport(originX: 0,    originY: 0, width: 1920, height: 1080, znear: 0, zfar: 1)
let rightViewport = MTLViewport(originX: 1920, originY: 0, width: 1920, height: 1080, znear: 0, zfar: 1)
encoder.setViewports([leftViewport, rightViewport])
// Draw quads once — vertex shader routes to correct eye via viewport_array_index
encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 2)
```

**Instance count = 2** is the key: one instance per eye. The vertex shader uses `[[viewport_array_index]]` to select the correct view/projection matrix.

### IOSurface → Metal Texture (Zero-Copy)

```swift
// In frame callback — create texture from IOSurface without CPU copy
guard let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }
let ioSurface = unsafeBitCast(surface, to: IOSurface.self)

let descriptor = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .bgra8Unorm,
    width: CVPixelBufferGetWidth(pixelBuffer),
    height: CVPixelBufferGetHeight(pixelBuffer),
    mipmapped: false
)
descriptor.storageMode = .shared  // REQUIRED for IOSurface textures on macOS
descriptor.usage = [.shaderRead]

let texture = device.makeTexture(descriptor: descriptor, iosurface: ioSurface, plane: 0)
```

The `storageMode = .shared` requirement is critical — IOSurface textures on macOS 13+ will assert-fail with private storage mode. The texture is a live view into the IOSurface memory: when ScreenCaptureKit updates the surface, the texture updates automatically — no copy needed.

### Projection Matrices

For v1 (3DOF, rotation only), the view matrix is derived purely from the Viture quaternion. Position is fixed (camera at world origin looking forward). IPD offset is applied between left and right eye view matrices:

```swift
let ipdHalfMeters: Float = 0.032  // 64mm IPD / 2 — verify against Viture optical spec
let leftEyeOffset  = simd_float4x4(translation: SIMD3(-ipdHalfMeters, 0, 0))
let rightEyeOffset = simd_float4x4(translation: SIMD3( ipdHalfMeters, 0, 0))
let rotation = simd_float4x4(vitureQuaternion)
let leftView  = leftEyeOffset  * rotation
let rightView = rightEyeOffset * rotation
```

Projection is a standard perspective matrix. FOV should match Viture's optical spec — approximately 42° horizontal per eye (verify from Viture hardware specs).

---

## Alternatives Considered

| Recommended | Alternative | When to Use Alternative |
|-------------|-------------|-------------------------|
| Metal (direct) | SceneKit | Never for this project — SceneKit owns the render loop and imposes a scene graph that fights a stereo texture-quad architecture |
| Metal (direct) | RealityKit | macOS RealityKit is designed for AR overlays on camera feeds, not custom stereo pipelines to external displays |
| Metal (direct) | OpenGL | OpenGL is deprecated on macOS 10.14+. Apple will remove it. Do not start new work on OpenGL. |
| `MTKView` + `CVDisplayLink` | Manually managed `CAMetalLayer` | Only if you need sub-frame timing control (you don't in v1). `MTKView` handles this correctly. |
| ScreenCaptureKit | `CGWindowListCreateImage` | Never for new work — deprecated in macOS 14, will trigger additional consent alerts in macOS 15 |
| ScreenCaptureKit | `CGDisplayStream` | Deprecated. Same issue as `CGWindowListCreateImage`. |
| C bridging header (Viture) | Swift Package Manager `.binaryTarget` | Use SPM if/when Viture ships an `.xcframework`. Until then, manual dylib linking is the only option. |
| AppKit (`NSWindow`/`NSView`) | SwiftUI + `MetalView` wrapper | SwiftUI adds unnecessary layout overhead for a fullscreen single-view rendering app. Use AppKit directly. |

---

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| SceneKit | Owns the render loop, imposes a scene graph, no direct viewport-array stereo support | Metal directly |
| RealityKit | Designed for visionOS / ARKit camera AR, not external display stereo; no public stereo pipeline control on macOS | Metal directly |
| OpenGL / OpenGL ES | Deprecated on macOS 10.14, will be removed, triggers deprecation warnings in Xcode 16 | Metal |
| `CGWindowListCreateImage` | Deprecated in macOS 14, triggers consent alerts in macOS 15 | ScreenCaptureKit |
| `CGDisplayStream` | Deprecated, lower-level and less capable than ScreenCaptureKit | ScreenCaptureKit |
| SwiftUI as app entry point | SwiftUI lifecycle and layout system is overhead for a fullscreen rendering app with no forms/lists | `NSApplication` + AppKit directly |
| CocoaPods | No Viture podspec exists; adds Cocoa dependency overhead to a framework-light project | Manual dylib linking in Xcode |
| `MTLStorageMode.private` on IOSurface textures | Asserts on macOS 13+; IOSurface-backed textures require `.shared` | `MTLStorageMode.shared` |
| `CVMetalTextureCacheCreateTextureFromImage` as primary path | Works, but `device.makeTexture(descriptor:iosurface:plane:)` is simpler and equally zero-copy for `CMSampleBuffer`-sourced IOSurfaces | `MTLDevice.makeTexture(descriptor:iosurface:plane:)` |

---

## Version Compatibility

| Requirement | Minimum | Recommended | Notes |
|-------------|---------|-------------|-------|
| macOS deployment target | 13.0 (Ventura) | 14.0 (Sonoma) | SCStreamConfiguration fully stable on 13. SCContentSharingPicker (picker UI) requires 14. Target 13 for now; bump to 14 when picker UX is added. |
| Xcode | 15 | 16 | Xcode 16 required for Swift 6 mode. Swift 5.10 (Xcode 15) is fine for v1. |
| Swift | 5.9 | 5.10 | No Swift 6 strict concurrency needed in v1. |
| Viture SDK | Latest from developer.viture.com | — | No versioned SPM/CocoaPods. Download manually. Confirm macOS arm64 binary is included. |
| Metal feature set | macOS GPU Family 1 | macOS GPU Family 2 | Multiple viewport (`setViewports`) requires Apple Silicon or AMD GCN2+ on Intel. All M-series Macs satisfy this. |

---

## Permissions and Entitlements

The app requires Screen Recording permission (TCC). This is granted by the user at runtime through the standard macOS Privacy prompt — it is not an entitlement you declare in the `.entitlements` file. There is no private entitlement for screen capture available to third-party apps.

In `Info.plist`, add `NSScreenCaptureUsageDescription` with a reason string. The system will show this when requesting permission.

USB device access to the Viture glasses via the SDK's internal `IOUSBHost` path is typically available to non-sandboxed apps without additional entitlements. If you distribute via the Mac App Store, USB access requires `com.apple.security.device.usb` entitlement and App Store review — distribute outside the store (direct download / notarized) for v1 to avoid this friction.

---

## Installation / Project Setup

This is a native Xcode project, not an SPM-only project. There are no `npm install` equivalents.

```bash
# 1. Create Xcode project: macOS App, Swift, Storyboard or XIB-free AppKit
# 2. Set deployment target: macOS 13.0
# 3. Add frameworks (all are system frameworks — no download needed):
#    Metal, MetalKit, ScreenCaptureKit, CoreVideo, CoreMedia, AppKit, simd

# 4. Download Viture XR Glasses SDK from developer.viture.com
#    Place libglasses.dylib (macOS arm64) into Packages/VitureSDK/
#    Place C headers into Packages/VitureSDK/include/

# 5. In Xcode target > Build Settings:
#    SWIFT_OBJC_BRIDGING_HEADER = Sources/VitureSDK-Bridging-Header.h
#    LIBRARY_SEARCH_PATHS = $(PROJECT_DIR)/Packages/VitureSDK
#    OTHER_LDFLAGS = -lglasses
#    LD_RUNPATH_SEARCH_PATHS = @loader_path/../Frameworks @loader_path

# 6. Embed libglasses.dylib in app bundle:
#    Target > Build Phases > Copy Files > Destination: Frameworks
```

---

## Sources

- [VITURE XR Glasses SDK documentation](https://www.viture.com/developer/glasses-sdk/glasses) — C API confirmed, macOS arm64/Sequoia support, pose data formats (7-float quaternion+position for Carina/Luma Ultra), polling vs callback distinction. MEDIUM confidence (no Swift wrapper found, no public GitHub).
- [ScreenCaptureKit — Apple Developer](https://developer.apple.com/documentation/screencapturekit/) — HIGH confidence.
- [Meet ScreenCaptureKit — WWDC22](https://developer.apple.com/videos/play/wwdc2022/10156/) — SCStream, SCStreamConfiguration, SCContentFilter API introduction. HIGH confidence.
- [What's new in ScreenCaptureKit — WWDC23](https://developer.apple.com/videos/play/wwdc2023/10136/) — SCContentSharingPicker, SCScreenshotManager, pixel format additions. HIGH confidence.
- [Capture HDR content with ScreenCaptureKit — WWDC24](https://developer.apple.com/videos/play/wwdc2024/10088/) — HDR, captureDynamicRange. HIGH confidence.
- [MTLDevice.makeTexture(descriptor:iosurface:plane:)](https://developer.apple.com/documentation/metal/mtldevice/maketexture(descriptor:iosurface:plane:)) — IOSurface → Metal texture zero-copy path. HIGH confidence.
- [Metal setViewports(_:)](https://developer.apple.com/documentation/metal/mtlrendercommandencoder/2869738-setviewports) — Multiple viewport support for stereo. HIGH confidence.
- [Oskar Groth — Rendering macOS in VR](https://oskargroth.com/blog/rendering-macos-in-vr) — IOSurface zero-copy window capture + instanced stereo viewport pattern in practice. MEDIUM confidence (community source, verified against Apple docs).
- [Embedding a dylib in a Swift Package — polpiella.dev](https://www.polpiella.dev/embedding-a-dylib-in-a-swift-package) — dylib embedding approach. MEDIUM confidence.

---

*Stack research for: macOS XR virtual desktop (Viture Luma Ultra)*
*Researched: 2026-04-14*
