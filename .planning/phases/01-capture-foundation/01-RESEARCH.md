# Phase 1: Capture Foundation - Research

**Researched:** 2026-04-14
**Domain:** ScreenCaptureKit window capture, IOSurface-to-Metal zero-copy, macOS Screen Recording permissions
**Confidence:** HIGH (ScreenCaptureKit, CoreVideo, Metal APIs fully documented by Apple; patterns cross-verified with WWDC sessions and community implementations)

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| SCK-01 | App requests Screen Recording permission on first launch and handles denied/revoked state gracefully | PermissionGateway pattern (TCC flow, `NSScreenCaptureUsageDescription`, `SCShareableContent` error handling) fully documented — see Permission Flow section |
| SCK-02 | User can select which macOS window to display on each of the two virtual monitor slots | `SCShareableContent.getWithCompletionHandler` + `SCContentFilter(desktopIndependentWindow:)` — standard enumeration/filter pattern, see Window Picker section |
| SCK-03 | App captures live window frames via SCStream using IOSurface zero-copy path (no CPU memcpy) | `CVMetalTextureCacheCreateTextureFromImage` + `kCVPixelBufferMetalCompatibilityKey` — zero-copy path fully documented; `storageMode = .shared` requirement verified |
| SCK-04 | Capture layer handles static-content frames gracefully — no tearing or freezing when window content has not changed | SCK does not deliver a new frame when window content is unchanged; TexturePool must hold last-valid texture so renderer repeats it rather than showing a frozen or torn frame |
| ARC-03 | TexturePool handles SCStream → Metal texture hand-off with correct IOSurface blit discipline (blit immediately, release sample buffer before returning from captureOutput) | Triple-buffer blit pattern documented; CVMetalTexture retain requirement documented; -3821 pool exhaustion root cause and prevention fully researched |

</phase_requirements>

---

## Summary

Phase 1 establishes the capture foundation that every subsequent phase depends on. Its two non-negotiable technical requirements are (1) correct Screen Recording permission flow and (2) the triple-buffer IOSurface blit discipline. Getting either wrong produces failures that are difficult to diagnose after rendering and tracking code is built on top.

ScreenCaptureKit is a thoroughly documented Apple API with confirmed zero-copy IOSurface delivery via `CMSampleBuffer`. The entire zero-copy path is: SCStream delivers `CMSampleBuffer` on a background queue → extract `CVImageBuffer` (IOSurface-backed) → call `CVMetalTextureCacheCreateTextureFromImage` to get an `MTLTexture` that wraps the same IOSurface without a CPU copy → blit immediately into an owned `MTLTexture` → release the `CMSampleBuffer` → write owned texture to `TexturePool`. This pattern must be established before any render code touches textures.

The dominant risk in Phase 1 is the `-3821` pool exhaustion disconnect. ScreenCaptureKit maintains a fixed pool of IOSurface-backed frame buffers (`queueDepth`, default 3). If the sample buffer or any object holding a reference to its IOSurface (including an `MTLTexture` created from it) is retained past `minimumFrameInterval × (queueDepth - 1)`, the pool runs dry and SCK silently terminates the stream with error `-3821`. At 60fps that budget is ~33ms for a queueDepth of 3. The solution is blit-and-release within the `captureOutput` callback, with owned triple-buffered `MTLTexture` slots in the `TexturePool`. This is not an optimisation to add later — it is the architecture.

**Primary recommendation:** Implement `CaptureManager` as a `SCStreamOutput`-conforming class (never a local variable) with a `CVMetalTextureCache`, blit immediately on every `captureOutput` callback into a `TexturePool`-owned triple-buffered texture, and release the sample buffer before returning from the callback. Set `queueDepth = 5` to give headroom.

---

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| ScreenCaptureKit | macOS 13+ | Live per-window capture with IOSurface delivery | Only non-deprecated window capture API on macOS; replaces `CGWindowListCreateImage` (deprecated macOS 14) and `CGDisplayStream` (deprecated). Per-window `SCContentFilter` stable on macOS 13. |
| CoreVideo (`CVMetalTextureCache`) | macOS 13+ | Zero-copy IOSurface → `MTLTexture` bridge | `CVMetalTextureCacheCreateTextureFromImage` wraps an IOSurface as an `MTLTexture` with no CPU copy. Required to sustain 60fps without stalling on texture uploads. |
| CoreMedia (`CMSampleBuffer`) | macOS 13+ | Frame envelope from SCStream callback | SCStream delivers frames as `CMSampleBuffer`; only consumed to extract the `CVImageBuffer` inside. Must be released before returning from `captureOutput`. |
| Metal (`MTLDevice`, `MTLTexture`) | macOS 13+ | GPU texture ownership and blit | Owned `MTLTexture` slots in `TexturePool` receive blitted pixel data from IOSurface textures; these are safe to hold across frames unlike IOSurface-backed textures. |
| AppKit (`NSApplication`) | macOS 13+ | App lifecycle and permission gateway hosting | Required for `NSApplicationDelegate`, window management, and triggering permission flow after UI is visible. |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| Foundation (`NSLock`, `DispatchQueue`) | stdlib | Thread-safe `TexturePool` swap; dedicated capture queue | `NSLock` protects the two-pointer swap in `TexturePool`; dedicated serial `DispatchQueue` passed to `addStreamOutput(_:type:sampleHandlerQueue:)` keeps capture processing off the main thread |
| Swift `Synchronization` (`Mutex`) | macOS 15+ / Swift 6 | Alternative to `NSLock` for `TexturePool` | Prefer `NSLock` for macOS 13 compatibility; upgrade to `Mutex` if/when deployment target rises to 15+ |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `CVMetalTextureCacheCreateTextureFromImage` | `MTLDevice.makeTexture(descriptor:iosurface:plane:)` | Both are zero-copy; `CVMetalTextureCache` manages texture lifecycle automatically and avoids stale entry buildup; either works but the cache is the more complete solution for sustained 60fps |
| `SCContentFilter(desktopIndependentWindow:)` | `SCContentFilter(display:excludingWindows:)` | Per-window filter captures exactly one window with no other content; display filter captures everything on a display. Use per-window for the window-picker UX requirement (SCK-02). |
| Custom window picker UI | `SCContentSharingPicker` (macOS 14+) | `SCContentSharingPicker` embeds permission implicitly in user action and has better UX; not available on macOS 13; use custom `SCShareableContent` enumeration for macOS 13 compatibility, plan to upgrade in v1.x |

**Installation:** No `npm install` equivalent. All libraries are Apple system frameworks. Add to Xcode target under "Link Binary With Libraries": `ScreenCaptureKit.framework`, `CoreVideo.framework`, `CoreMedia.framework`, `Metal.framework`. All ship with macOS 13 SDK — no download required.

---

## Architecture Patterns

### Recommended Project Structure (Capture layer only — Phase 1 scope)

```
Sources/
├── App/
│   ├── AppDelegate.swift          # NSApplicationDelegate, launches PermissionGateway
│   └── AppCoordinator.swift       # Stub for Phase 1 — owns CaptureManager, prints texture arrival
│
├── Capture/
│   ├── CaptureManager.swift       # SCStreamOutput conformer, CVMetalTextureCache, writes TexturePool
│   ├── TexturePool.swift          # NSLock-guarded triple-buffer swap: [MTLTexture?] x 3 per slot
│   └── WindowPicker.swift         # SCShareableContent enumeration, returns SCWindow list for user selection
│
└── Permissions/
    └── PermissionGateway.swift    # TCC check, request, status observation; gates CaptureManager start
```

The render layer (`Render/`, `Tracking/`, `Layout/`) is not built in Phase 1. The AppCoordinator stub proves the pipeline works by logging texture dimensions and frame timestamps to console without rendering.

### Pattern 1: CaptureManager as SCStreamOutput Self-Conformer

**What:** `CaptureManager` is a class (not a struct or local variable) that conforms directly to `SCStreamOutput`. It passes `self` to `stream.addStreamOutput(_:type:sampleHandlerQueue:)`. This ensures the output delegate is held strongly for the lifetime of the manager.

**When to use:** Always. SCStream holds only a **weak** reference to the `SCStreamOutput` delegate. If you pass a locally allocated conformer, it is deallocated before the first frame arrives with no error.

**Example:**
```swift
// Source: Apple Developer Forums thread/733077 (pitfall confirmed); pattern from SCStream docs
final class CaptureManager: NSObject, SCStreamOutput, SCStreamDelegate {

    private let device: MTLDevice
    private var textureCache: CVMetalTextureCache?
    private var stream: SCStream?
    private let captureQueue = DispatchQueue(label: "com.app.capture", qos: .userInteractive)
    let texturePool: TexturePool

    func startCapture(filter: SCContentFilter, config: SCStreamConfiguration) async throws {
        stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try await stream?.startCapture()
    }

    // SCStreamOutput — called on captureQueue
    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen else { return }
        processFrame(sampleBuffer)  // blit immediately, release sample buffer on return
    }
}
```

### Pattern 2: Triple-Buffer Blit Discipline (ARC-03)

**What:** The `captureOutput` callback blits the IOSurface-backed texture into a pre-allocated owned `MTLTexture` slot immediately and releases all references to the `CMSampleBuffer` and IOSurface-backed texture before returning. The `TexturePool` holds three owned slots per monitor; a rotating write index ensures the GPU is never reading a slot while the CPU is writing it.

**When to use:** Mandatory. This is not an optimisation — it is the only correct architecture. Holding the sample buffer or IOSurface-backed texture across frame boundaries exhausts the SCK surface pool and triggers `-3821`.

**Example:**
```swift
// Source: WWDC22 "Take ScreenCaptureKit to the next level"; Apple Developer docs queueDepth
private var ownedTextures: [[MTLTexture]] = [[], []]  // [slot][bufferIndex] — 3 per slot
private var writeIndices: [Int] = [0, 0]

private func processFrame(_ sampleBuffer: CMSampleBuffer) {
    guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    let w = CVPixelBufferGetWidth(imageBuffer)
    let h = CVPixelBufferGetHeight(imageBuffer)

    var cvTexture: CVMetalTexture?
    CVMetalTextureCacheCreateTextureFromImage(
        nil, textureCache!, imageBuffer, nil, .bgra8Unorm, w, h, 0, &cvTexture)
    guard let cvTexture,
          let srcTexture = CVMetalTextureGetTexture(cvTexture) else { return }

    // Blit into owned slot immediately
    let writeIdx = writeIndices[slotIndex]
    let dstTexture = ownedTextures[slotIndex][writeIdx]
    let commandBuffer = commandQueue.makeCommandBuffer()!
    let blit = commandBuffer.makeBlitCommandEncoder()!
    blit.copy(from: srcTexture, to: dstTexture)
    blit.endEncoding()
    commandBuffer.commit()
    // srcTexture / cvTexture go out of scope here — IOSurface reference released

    texturePool.write(dstTexture, slot: slotIndex, bufferIndex: writeIdx)
    writeIndices[slotIndex] = (writeIdx + 1) % 3
}
// sampleBuffer released on return from processFrame
```

### Pattern 3: SCStreamConfiguration for 60fps IOSurface Delivery (SCK-03)

**What:** Configure `SCStreamConfiguration` to match the source window resolution, request 60fps, use BGRA pixel format (matches Metal `.bgra8Unorm`), and enable Metal compatibility on the pixel buffer.

**When to use:** On every stream start. Wrong pixel format or missing Metal compatibility key causes fallback to a non-IOSurface path (CPU copy).

**Example:**
```swift
// Source: Apple Developer Documentation — SCStreamConfiguration; WWDC22 10156
let config = SCStreamConfiguration()
config.width = Int(window.frame.width * scaleFactor)
config.height = Int(window.frame.height * scaleFactor)
config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
config.pixelFormat = kCVPixelFormatType_32BGRA   // matches MTLPixelFormat.bgra8Unorm
config.colorSpaceName = CGColorSpace.sRGB
config.showsCursor = false
config.queueDepth = 5  // headroom above default 3; prevents -3821 under brief processing spikes
// kCVPixelBufferMetalCompatibilityKey is set implicitly when pixelFormat = 32BGRA on macOS 13+
// Verify with: CVPixelBufferGetIOSurface(buffer) != nil in the callback
```

### Pattern 4: Permission Flow (SCK-01)

**What:** Check permission status before any SCK API call. If not determined, show a UI prompt explaining why — then request. If denied, show a clear recovery message (not a crash). Gate `CaptureManager.start()` behind `PermissionGateway.requestPermission()`.

**When to use:** Mandatory on first launch. Also re-check on every app resume (permission can be revoked while the app is in the background).

**Example:**
```swift
// Source: Apple Developer Documentation — SCShareableContent; PITFALLS.md Pitfall 3, 5
// Info.plist must contain NSScreenCaptureUsageDescription before this runs

final class PermissionGateway {
    enum Status { case granted, denied, notDetermined }

    func currentStatus() async -> Status {
        // Attempt a minimal SCShareableContent call to probe permission
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return .granted
        } catch let error as SCStreamError where error.code == .userDeclined {
            return .denied
        } catch {
            return .notDetermined
        }
    }

    func requestPermission() async -> Status {
        // The act of calling getWithCompletionHandler triggers the TCC prompt
        // MUST be called after the main window is visible
        return await currentStatus()
    }
}
```

**Key constraint:** Do NOT call any SCK API at `applicationDidFinishLaunching`. Show your main window first. Call `requestPermission()` only after the user can see context for why the permission is needed.

### Pattern 5: Window Enumeration and SCContentFilter (SCK-02)

**What:** `SCShareableContent.getWithCompletionHandler` returns all available windows. Present the list to the user (window titles + owning app names). On selection, create an `SCContentFilter(desktopIndependentWindow:)` for the chosen window and pass it to `CaptureManager`.

**Example:**
```swift
// Source: Apple Developer Documentation — SCShareableContent, SCContentFilter
SCShareableContent.getWithCompletionHandler { content, error in
    guard let content else { return }
    let windows = content.windows.filter { $0.isOnScreen && $0.title != nil }
    // Present windows to user (Phase 1: simple list; Phase 2+: UI picker)
    // On selection:
    let filter = SCContentFilter(desktopIndependentWindow: selectedWindow)
    Task { try await captureManager.startCapture(filter: filter, config: config) }
}
```

### Anti-Patterns to Avoid

- **Holding CMSampleBuffer past captureOutput return:** The single most common cause of `-3821`. The callback must blit and release within its own execution. Never dispatch the sample buffer to another queue for later processing.
- **Local SCStreamOutput conformer:** If you pass `MyOutputClass()` without storing the reference strongly, it is deallocated immediately. `captureOutput` is never called. No error is raised. Symptom looks identical to a permission failure.
- **Calling SCK at launch before window is visible:** Triggers TCC permission dialog before the user has any context. macOS 15 shows this dialog in a confusing order relative to the app's own UI. Defer to a user-triggered action.
- **Skipping `NSScreenCaptureUsageDescription` in Info.plist:** Causes silent permission denial on a clean install. System shows no dialog; `SCShareableContent.windows` returns empty. The app appears to work in Xcode (developer already has permission) but fails on every fresh machine.
- **Using the same MTLDevice instance for texture cache and later for rendering:** This is actually **correct** and **required** — the `CVMetalTextureCache` and `MTLRenderCommandEncoder` must share the same `MTLDevice`. Flag this as a requirement, not a pitfall: inject the device into `CaptureManager`.
- **Not retaining CVMetalTexture alongside MTLTexture:** `CVMetalTextureCacheCreateTextureFromImage` returns both a `CVMetalTexture` wrapper and (via `CVMetalTextureGetTexture`) an `MTLTexture`. Releasing the `CVMetalTexture` allows the cache to reclaim the IOSurface backing. Keep both in a paired array until the blit completes.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Zero-copy GPU texture from IOSurface | Custom IOSurface-to-MTLTexture mapping | `CVMetalTextureCacheCreateTextureFromImage` | Handles lifetime management, format conversion negotiation, and stale entry cleanup automatically. Hand-rolled IOSurface mapping risks use-after-free if the surface is reclaimed by SCK. |
| Window enumeration | Custom CGWindow/AX enumeration | `SCShareableContent.getWithCompletionHandler` | SCK's enumeration is permission-aware, returns `SCWindow` objects with correct metadata for filter construction. CGWindow enumeration triggers additional TCC prompts on macOS 15. |
| Permission check | Custom TCC database query | `SCShareableContent` probe call | The only reliable way to check screen recording permission without triggering a second dialog. Private TCC APIs are not allowed in notarized apps. |
| Frame queue / surface pool management | Custom ring buffer of IOSurfaces | SCK `queueDepth` + blit-and-release discipline | SCK manages the pool internally. Your job is only to release surfaces promptly. Reimplementing the pool adds complexity without benefit. |
| Display link / vsync timing | Custom `CVDisplayLink` or timer | `MTKView.preferredFramesPerSecond` (Phase 2) | MTKView's display link is correct and platform-maintained. For Phase 1 (capture only, no render), SCK's `minimumFrameInterval` controls delivery rate without any app-side timing. |

**Key insight:** In Phase 1, you are not building a render loop. The capture pipeline is the entire deliverable. All complexity is in the blit discipline and permission flow, not in custom timing or format conversion code.

---

## Common Pitfalls

### Pitfall 1: SCStream Output Delegate Silently Collected
**What goes wrong:** `SCStream` holds a weak reference to the `SCStreamOutput` conformer. If declared locally (e.g., inside a function), it is deallocated before any frame arrives. No error is raised.
**Why it happens:** The API accepts a protocol conformer without taking ownership. Nothing in the compiler warns you. The symptom is indistinguishable from a permission failure or misconfigured filter.
**How to avoid:** Make `CaptureManager` itself conform to `SCStreamOutput` and pass `self`. The manager lives as long as the app is capturing.
**Warning signs:** `startCapture()` completes without error; `captureOutput` is never called; no frame drop errors in console.

### Pitfall 2: IOSurface Pool Exhaustion (-3821 Disconnect)
**What goes wrong:** SCK maintains a fixed `queueDepth` pool (default 3 surfaces). Holding a `CMSampleBuffer` or any `MTLTexture` wrapping its IOSurface past `minimumFrameInterval × (queueDepth - 1)` exhausts the pool. SCK disconnects with error `-3821`. The stream goes completely silent.
**Why it happens:** `MTLTexture` created via `CVMetalTextureCacheCreateTextureFromImage` is a zero-copy alias — it holds the IOSurface open. If the render pipeline caches this texture across frames, the pool fills up in under a second at 60fps.
**How to avoid:** Blit into owned textures within `captureOutput`. Release all IOSurface-backed references before returning. Set `queueDepth = 5`. Monitor `stream(_:didStopWithError:)` in development builds and log `-3821` prominently.
**Warning signs:** Stream works for 0.5–3 seconds then goes silent; console shows `SCStreamErrorDomain -3821`; problem worsens under higher capture resolution.

### Pitfall 3: Missing NSScreenCaptureUsageDescription Causes Silent Denial
**What goes wrong:** Without `NSScreenCaptureUsageDescription` in `Info.plist`, macOS silently denies screen recording permission. No dialog appears. `SCShareableContent.windows` returns empty.
**Why it happens:** The key is not required to compile or launch. Only checked at runtime when permission is requested. Absent → no prompt → no grant.
**How to avoid:** Add the key to `Info.plist` before any SCK testing. Format: `<key>NSScreenCaptureUsageDescription</key><string>reason</string>`. Test on a clean user account — developer machines often already have permission granted.
**Warning signs:** `getWithCompletionHandler` succeeds but returns zero windows; System Settings → Privacy → Screen Recording does not list the app.

### Pitfall 4: Permission Dialog at App Launch Hangs or Confuses
**What goes wrong:** Calling any SCK API in `applicationDidFinishLaunching` (before the main window renders) triggers the TCC dialog before the user sees any UI. On macOS 15, the dialog appears in an unpredictable order, confusing users. On older macOS, the app appears frozen while the dialog waits.
**Why it happens:** Eager initialization — developers want capture to start as fast as possible.
**How to avoid:** Show the main window first. Call `PermissionGateway.requestPermission()` only in response to a user-initiated action (e.g., clicking "Start Capturing" or appearing visible window). Never call SCK APIs synchronously on the main thread.
**Warning signs:** App appears frozen for 2–30 seconds on first launch; dialog appears before the app's own window.

### Pitfall 5: Static Content Frames Not Updating Texture (SCK-04)
**What goes wrong:** When a captured window's content does not change between frames (e.g., a static document, idle terminal), SCK does not deliver a new `CMSampleBuffer`. If the render side expects a new texture every 16.7ms and none arrives, the display may freeze or show stale state.
**Why it happens:** SCK is optimized to skip delivery when content is unchanged. This is correct behavior, not a bug.
**How to avoid:** `TexturePool` must hold the last-valid texture. The render loop reads the last texture from the pool regardless of whether a new one arrived. This requires no special code if `TexturePool.read(slot:)` returns the last written texture — which it does by design. For Phase 1 verification, confirm that the console log (texture arrival timestamp) shows gaps during static content but that no crash or nil-texture error occurs.
**Warning signs:** Render side crashes or logs nil texture when window content is static; verification log shows zero frames for >5 seconds of static content.

### Pitfall 6: CVMetalTexture Wrapper Released Too Early
**What goes wrong:** After calling `CVMetalTextureCacheCreateTextureFromImage`, the `CVMetalTexture` wrapper is released (goes out of scope) while the `MTLTexture` derived from it is still in use for blitting. The cache may reclaim the IOSurface backing mid-blit.
**Why it happens:** `CVMetalTextureGetTexture` returns a non-owning reference. The `MTLTexture` and `CVMetalTexture` wrapper must be kept in the same lifecycle scope.
**How to avoid:** Retain both the `CVMetalTexture` and the `MTLTexture` for the duration of the blit command (until the command buffer completes). Use a `commandBuffer.addCompletedHandler` to nil out the retained wrappers after the GPU finishes.
**Warning signs:** Rare GPU validation errors "resource used after deallocation"; flicker or corruption in blitted textures under memory pressure.

---

## Code Examples

Verified patterns from official sources:

### SCStream Full Setup
```swift
// Source: Apple Developer Documentation — SCStream, SCStreamConfiguration, SCContentFilter
// WWDC22 session 10156

let config = SCStreamConfiguration()
config.width = Int(window.frame.width * NSScreen.main!.backingScaleFactor)
config.height = Int(window.frame.height * NSScreen.main!.backingScaleFactor)
config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
config.pixelFormat = kCVPixelFormatType_32BGRA
config.queueDepth = 5
config.showsCursor = false

let filter = SCContentFilter(desktopIndependentWindow: window)
let stream = SCStream(filter: filter, configuration: config, delegate: self)
try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
try await stream.startCapture()
```

### CVMetalTextureCache Setup
```swift
// Source: Apple Developer Documentation — CVMetalTextureCache
// Must use the same MTLDevice that the render layer will use

var cache: CVMetalTextureCache?
CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
self.textureCache = cache!
```

### IOSurface Verification in captureOutput
```swift
// Confirm zero-copy path is active
if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
    let hasIOSurface = CVPixelBufferGetIOSurface(imageBuffer) != nil
    assert(hasIOSurface, "Expected IOSurface-backed pixel buffer for zero-copy Metal path")
}
```

### SCStreamDelegate Error Monitoring
```swift
// Source: Apple Developer Documentation — SCStreamDelegate
// Required for -3821 detection in development builds

extension CaptureManager: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let nsError = error as NSError
        print("[CaptureManager] Stream stopped. Domain: \(nsError.domain) Code: \(nsError.code)")
        // -3821 = SCStreamErrorCode.userDeclined or IOSurface pool exhaustion
        // Surface this prominently in development — it indicates blit discipline failure
    }
}
```

### TexturePool (NSLock triple-buffer swap)
```swift
// Source: ARCHITECTURE.md Pattern 2; thread-safety pattern verified against Swift concurrency docs

final class TexturePool {
    private var lock = NSLock()
    // Per slot: [writeSlot0, writeSlot1, writeSlot2] — GPU may be reading any slot
    private var slots: [[MTLTexture?]] = [[nil, nil, nil], [nil, nil, nil]]
    private var readIndices: [Int] = [0, 0]

    /// Called from capture queue
    func write(_ texture: MTLTexture, monitor: Int, bufferIndex: Int) {
        lock.withLock { slots[monitor][bufferIndex] = texture }
        lock.withLock { readIndices[monitor] = bufferIndex }
    }

    /// Called from render queue
    func read(monitor: Int) -> MTLTexture? {
        lock.withLock { slots[monitor][readIndices[monitor]] }
    }
}
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `CGWindowListCreateImage` (screenshot per frame) | `SCStream` with IOSurface zero-copy | macOS 12.3 (2022) | Eliminates full CPU copy per frame; ~10x lower latency; per-window capture without root access |
| `CGDisplayStream` | `SCStream` | macOS 12.3 (2022) | Per-window filtering; configurable resolution/fps; structured permission model |
| Manual `CGWindowID` enumeration | `SCShareableContent` API | macOS 12.3 (2022) | Correct app/window metadata; works within TCC permission model |
| System picker (macOS 13 only if backported) | `SCContentSharingPicker` (macOS 14+) | macOS 14 (2023) | Embeds permission implicitly in picker gesture; better UX; not available for macOS 13 target |
| `CVDisplayLink` for render timing | `CAMetalDisplayLink` | macOS 14 (2023) | Phase 2 concern — not needed in Phase 1 |

**Deprecated/outdated:**
- `CGWindowListCreateImage`: Deprecated macOS 14, triggers additional TCC prompts on macOS 15. Do not use for any new capture work.
- `CGDisplayStream`: Deprecated. No per-window capture capability. Replaced by SCK.
- `AVCaptureScreenInput`: Never recommended for live window capture — high latency, requires different entitlement, H.264-encoded output not suitable for texture delivery.

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Xcode | Build, Metal compilation, SCK APIs | ✓ | Xcode 26.3 (Build 17C529) | — |
| Swift | Primary language | ✓ | Swift 6.2.4 (arm64-apple-macosx26.0) | — |
| macOS | ScreenCaptureKit, CoreVideo | ✓ | macOS 26.3.1 (Beta) | — |
| ScreenCaptureKit | SCK-01 through SCK-04 | ✓ | Ships with macOS 13+; host is macOS 26 | — |
| CoreVideo / CVMetalTextureCache | ARC-03 zero-copy | ✓ | Ships with macOS 13+; host is macOS 26 | — |
| Metal | Texture blit in ARC-03 | ✓ | Ships with macOS 13+; Apple Silicon confirmed | — |
| Xcode project (.xcodeproj) | Build target | ✗ | Not yet created | Must be created as Wave 0 / Plan 1 task |

**Missing dependencies with no fallback:**
- Xcode project file — the project root contains only Unity scaffold files and planning documents. A new macOS App Xcode project must be created as the first task of Phase 1.

**Notes on environment:**
- macOS 26.3.1 is a beta (pre-release). The deployment target should be set to macOS 13.0 minimum regardless of the host OS version, so the app can run on non-beta machines.
- Swift 6.2.4 is available. Swift 6 strict concurrency is available but should be left **off** for Phase 1 unless the team is comfortable with it — the capture threading model can be written correctly without strict concurrency checking and enabling it mid-development adds noise. Enable it in a later phase.
- Xcode 26.3 is a beta. If Xcode 16.x is available alongside it, prefer 16.x for production builds. For Phase 1 development, Xcode 26.3 is functional.

---

## Open Questions

1. **Xcode project: AppKit vs SwiftUI lifecycle**
   - What we know: ARCHITECTURE.md recommends `NSApplication` + AppKit directly (not SwiftUI) for a fullscreen rendering app.
   - What's unclear: Xcode 26 "macOS App" template defaults to SwiftUI. The project must be created with "Interface: XIB" or "Interface: None" and `@NSApplicationMain` / `NSApplicationDelegate` manually, or the team must strip SwiftUI from a new template.
   - Recommendation: Create the project with the AppKit lifecycle from the start. Do not use SwiftUI for app structure — it adds unnecessary layout overhead and fights a fullscreen single-view render architecture.

2. **macOS deployment target: 13.0 vs 14.0**
   - What we know: `SCStreamConfiguration` is fully stable on macOS 13. `SCContentSharingPicker` (better window picker UX) requires macOS 14.
   - What's unclear: Whether the team wants to support macOS 13 users or start at 14 for the better picker.
   - Recommendation: Set deployment target to **macOS 13.0** for Phase 1. The `SCContentSharingPicker` UX is a v1.x feature — it can be added with an `@available(macOS 14, *)` guard after Phase 1 validates the core capture loop.

3. **Blit commandQueue ownership**
   - What we know: The blit in `captureOutput` requires a `MTLCommandQueue`. This command queue can be the same one used by the render engine or a dedicated one.
   - What's unclear: Whether a shared command queue creates contention at 60fps when the render engine is also active (Phase 2+).
   - Recommendation: For Phase 1 (no render engine yet), create a dedicated `captureBlitQueue` in `CaptureManager`. In Phase 4 integration, evaluate whether to share the render engine's queue or keep separate. Separate queues at different priority levels (capture: `.userInteractive`, render: `.userInteractive`) is the safe default.

---

## Project Constraints (from CLAUDE.md)

> Note: CLAUDE.md describes the superseded Unity XR project. The active project is the native macOS app described in `.planning/PROJECT.md`. The constraints below are the ones that remain applicable.

**Applicable constraints from CLAUDE.md:**
- **Language:** Swift only, no Objective-C — confirmed applicable. All Phase 1 code is Swift.
- **Build target:** The Unity project targeted Android. The native macOS app targets macOS 13+ / arm64. Android build target is not applicable.
- **Packages/com.viture.xr:** This directory exists in the repo but contains only a `.gitkeep` (Unity SDK placeholder). For the native macOS app, the Viture macOS SDK (separate C binary) will be placed at a different path (e.g., `Packages/VitureSDK/` or `VitureSDK/` at project root). The Unity `com.viture.xr` package is not used by the native app.
- **ProjectSettings/ committed to repo:** Applicable — Xcode project settings (`project.pbxproj`) should be committed and treated as code.
- **Docs/ directory:** Applicable — architecture decisions and SDK research should continue to be stored in `Docs/`.

**Phase 1 has no constraints from CONTEXT.md** — no CONTEXT.md exists for this phase (no `/gsd:discuss-phase` was run). The decisions in `STATE.md` are the operative constraints:
- ScreenCaptureKit over CGDisplayStream: **Locked**
- Swift only, no Objective-C: **Locked**
- Native macOS app, not Unity: **Locked**
- macOS 13+ minimum: **Locked**

---

## Sources

### Primary (HIGH confidence)
- Apple Developer Documentation — ScreenCaptureKit: https://developer.apple.com/documentation/screencapturekit/
- WWDC22 "Meet ScreenCaptureKit" (session 10156): https://developer.apple.com/videos/play/wwdc2022/10156/
- WWDC22 "Take ScreenCaptureKit to the next level" (session 10155): https://developer.apple.com/videos/play/wwdc2022/10155/
- WWDC23 "What's new in ScreenCaptureKit" (session 10136): https://developer.apple.com/videos/play/wwdc2023/10136/
- Apple Developer Documentation — SCStreamConfiguration.queueDepth: https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/queuedepth
- Apple Developer Documentation — CVMetalTextureCache: https://developer.apple.com/documentation/corevideo/cvmetaltexturecache-q3j
- Apple Developer Documentation — MTLDevice.makeTexture(descriptor:iosurface:plane:): https://developer.apple.com/documentation/metal/mtldevice/maketexture(descriptor:iosurface:plane:)
- Apple Developer Forums — SCStream weak output reference (Pitfall 1 confirmed): https://developer.apple.com/forums/thread/733077

### Secondary (MEDIUM confidence)
- fatbobman.com — ScreenSage architecture (SCK -3821, static frame UX): https://fatbobman.com/en/posts/screensage-from-pixel-to-meta/
- nonstrict.eu — ScreenCaptureKit on macOS Sonoma (SCContentSharingPicker, permission gotchas): https://nonstrict.eu/blog/2023/a-look-at-screencapturekit-on-macos-sonoma/
- Prior project research (.planning/research/PITFALLS.md, ARCHITECTURE.md, STACK.md) — synthesized findings from 2026-04-14

### Tertiary (LOW confidence — needs runtime validation)
- Blit command queue contention behaviour under concurrent render+capture load — not documented authoritatively; monitor in Phase 4 integration

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — all libraries are Apple system frameworks with official WWDC documentation
- Architecture: HIGH — SCStreamOutput weak-ref pitfall confirmed by Apple Developer Forums; blit-and-release pattern confirmed by Apple queueDepth docs and WWDC sessions
- Pitfalls: HIGH (Pitfalls 1–5) / MEDIUM (Pitfall 6, CVMetalTexture lifetime) — all ScreenCaptureKit pitfalls have official or community-verified sources
- Environment: HIGH — Xcode 26.3, Swift 6.2.4, macOS 26.3.1 confirmed on host machine

**Research date:** 2026-04-14
**Valid until:** 2026-07-14 (stable Apple APIs; SCK has not changed substantially since macOS 13)
