# Architecture Research

**Domain:** macOS XR virtual desktop — native Swift + Metal + ScreenCaptureKit
**Researched:** 2026-04-14
**Confidence:** HIGH (Metal multi-viewport, SCStream threading, CVMetalTextureCache patterns are well-documented Apple APIs; Viture macOS SDK details are MEDIUM — confirmed to exist but internal API shape not yet inspected)

---

## Standard Architecture

### System Overview

```
┌──────────────────────────────────────────────────────────────────┐
│                        APPLICATION LAYER                          │
│  ┌──────────────┐  ┌─────────────────┐  ┌─────────────────────┐  │
│  │ AppDelegate  │  │  WindowManager  │  │ PermissionGateway   │  │
│  │ (entry, menu)│  │ (layout config) │  │ (SCK permission)    │  │
│  └──────┬───────┘  └────────┬────────┘  └─────────────────────┘  │
└─────────┼───────────────────┼──────────────────────────────────── ┘
          │                   │
┌─────────▼───────────────────▼──────────────────────────────────── ┐
│                       COORDINATOR LAYER                            │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                    AppCoordinator                            │   │
│  │  Owns CaptureManager, RenderEngine, TrackingProvider,        │   │
│  │  VirtualMonitorLayout. Wires the data flow at startup.       │   │
│  └──────┬────────────────────────┬───────────────────┬─────────┘   │
└─────────┼────────────────────────┼───────────────────┼─────────────┘
          │                        │                   │
┌─────────▼────────┐  ┌────────────▼──────┐  ┌────────▼──────────────┐
│  CAPTURE LAYER   │  │  TRACKING LAYER   │  │   RENDER LAYER        │
│                  │  │                   │  │                        │
│  CaptureManager  │  │  TrackingProvider │  │  RenderEngine          │
│  ┌────────────┐  │  │  (protocol)       │  │  ┌──────────────────┐  │
│  │ SCFilter   │  │  │  ┌─────────────┐  │  │  │ MTKView          │  │
│  │ SCStream   │  │  │  │VitureTracker│  │  │  │ MTLDevice        │  │
│  │ TexturePool│  │  │  │ (3DOF impl) │  │  │  │ CommandQueue     │  │
│  └────────────┘  │  │  └─────────────┘  │  │  │ PipelineState    │  │
│                  │  │  ┌─────────────┐  │  │  │ QuadMesh x2      │  │
│  Publishes:      │  │  │SixDOFTracker│  │  │  └──────────────────┘  │
│  MTLTexture[2]   │  │  │ (v2 drop-in)│  │  │                        │
│  per frame       │  │  └─────────────┘  │  │  Reads:               │
│                  │  │                   │  │  MTLTexture[2],        │
└──────────────────┘  │  Publishes:       │  │  HeadPose,             │
                      │  HeadPose struct  │  │  VirtualMonitorLayout  │
                      └───────────────────┘  └────────────────────────┘
```

### Component Responsibilities

| Component | Responsibility | Owns |
|-----------|----------------|------|
| `AppCoordinator` | Wires all subsystems at startup; holds the lifecycle | References to all layer objects |
| `CaptureManager` | Creates SCFilter, starts SCStream per monitor slot, pools CVMetalTextureCache, publishes current `MTLTexture` per slot | SCStream, CVMetalTextureCache, DispatchQueue (capture) |
| `TrackingProvider` | Protocol. Delivers `HeadPose` on every display-refresh | Nothing — implementors own their SDKs |
| `VitureTracker` | Concrete `TrackingProvider` wrapping Viture macOS SDK callbacks | Viture SDK handle, IMU callback registration |
| `SixDOFTracker` | Future concrete `TrackingProvider` adding positional offset on top of IMU | Viture SDK + positional fusion |
| `RenderEngine` | Builds Metal pipeline, owns MTKView, renders two textured quads per frame using the latest textures and head pose | MTLDevice, MTLCommandQueue, pipeline state objects, vertex buffers |
| `VirtualMonitorLayout` | Value type. Holds world-space anchor position, size, and IPD for each quad | Pure data; no threading |
| `WindowManager` | Enumerates available `SCWindow`s, lets user pick two; rebuilds SCFilter on change | SCShareableContent |
| `PermissionGateway` | Requests ScreenCaptureKit screen-recording permission; gates startup | None beyond system permission |

---

## Recommended Project Structure

```
Sources/
├── App/
│   ├── AppDelegate.swift          # NSApplicationDelegate, menu bar
│   └── AppCoordinator.swift       # Wires all subsystems, owns their lifetimes
│
├── Capture/
│   ├── CaptureManager.swift       # SCStream setup, CVMetalTextureCache, texture publish
│   ├── TexturePool.swift          # Thread-safe atomic swap of latest MTLTexture per slot
│   └── WindowPicker.swift         # SCShareableContent enumeration, window selection UI
│
├── Tracking/
│   ├── TrackingProvider.swift     # Protocol + HeadPose struct
│   ├── VitureTracker.swift        # Viture macOS SDK wrapper (3DOF)
│   └── SixDOFTracker.swift        # v2 placeholder — positional extension
│
├── Render/
│   ├── RenderEngine.swift         # MTKViewDelegate, command encoding, stereo draw
│   ├── QuadMesh.swift             # Vertex buffer for a single textured quad
│   ├── StereoCamera.swift         # Projection + view matrix pair from HeadPose + layout
│   └── Shaders.metal              # Vertex + fragment shader; viewport_array_index for stereo
│
├── Layout/
│   └── VirtualMonitorLayout.swift # World-space anchor, size, IPD — pure value type
│
└── Permissions/
    └── PermissionGateway.swift    # SCK permission request + status observation
```

### Structure Rationale

- **Capture/**: Isolated from rendering. Owns all ScreenCaptureKit types. Nothing outside this folder imports `ScreenCaptureKit`.
- **Tracking/**: Protocol-backed so v2 drops in a new file with no render-layer changes.
- **Render/**: Owns all `Metal` imports. Consumes textures and pose as plain values — no knowledge of where they came from.
- **Layout/**: Deliberately a pure value type. Can be serialized, diffed, and passed across queues without locking.

---

## Architectural Patterns

### Pattern 1: Protocol-Backed TrackingProvider

**What:** A Swift protocol defines the single contract for head-pose delivery. Each concrete provider (3DOF IMU, 6DOF fusion, mock) is a separate class conforming to the protocol.

**When to use:** Any time a subsystem has multiple interchangeable implementations. Especially important here because the Viture macOS SDK callback shape is SDK-internal and must not leak into the render layer.

**Trade-offs:** Adds one indirection hop per frame; negligible at 60–120 Hz. Eliminates entire refactor cost when 6DOF is added.

```swift
// Tracking/TrackingProvider.swift
struct HeadPose {
    var orientation: simd_quatf   // rotation in world space
    var position: SIMD3<Float>    // metres; zero for 3DOF, populated by 6DOF
    var timestamp: TimeInterval
}

protocol TrackingProvider: AnyObject {
    /// Called on an arbitrary background thread by the SDK.
    /// Implementations must be thread-safe.
    var onPoseUpdate: ((HeadPose) -> Void)? { get set }
    func start()
    func stop()
}

// Tracking/VitureTracker.swift
final class VitureTracker: TrackingProvider {
    var onPoseUpdate: ((HeadPose) -> Void)?
    // Registers with Viture macOS SDK IMU callback.
    // Converts SDK quaternion to HeadPose and calls onPoseUpdate.
    func start() { /* SDK start */ }
    func stop()  { /* SDK stop  */ }
}

// v2: drop in SixDOFTracker.swift — zero changes to RenderEngine
```

### Pattern 2: Atomic Texture Swap (TexturePool)

**What:** `CaptureManager` writes newly arrived `MTLTexture` references into a `TexturePool`. The render loop reads from `TexturePool` every frame. No locks; uses a single `nonisolated(unsafe) var` with an `NSLock` (or Swift `Mutex` from Synchronization framework on macOS 15+) to protect the swap.

**When to use:** SCStream callbacks arrive on a private background queue. The Metal render loop runs on a different queue driven by `MTKView`. These two queues must share texture references without blocking either.

**Trade-offs:** One extra pointer copy per frame (negligible). Requires careful retain/release accounting so the GPU finishes before the texture is reused. Simpler than a lock-free ring buffer; correct and fast enough for 60–120 Hz.

```swift
// Capture/TexturePool.swift
final class TexturePool {
    private var lock = NSLock()
    private var slots: [MTLTexture?] = [nil, nil]  // index 0 = monitor A, 1 = monitor B

    func write(_ texture: MTLTexture, slot: Int) {
        lock.withLock { slots[slot] = texture }
    }

    func read(slot: Int) -> MTLTexture? {
        lock.withLock { slots[slot] }
    }
}
```

### Pattern 3: CVMetalTextureCache Zero-Copy Upload

**What:** `CaptureManager` holds one `CVMetalTextureCache` backed by the `MTLDevice`. When SCStream delivers a `CMSampleBuffer`, extract the `CVImageBuffer` (backed by `IOSurface`) and call `CVMetalTextureCacheCreateTextureFromImage`. The resulting `MTLTexture` is a zero-copy view — the GPU reads from the same IOSurface that ScreenCaptureKit wrote.

**When to use:** Always. This eliminates a full frame copy on every SCStream callback. On Apple Silicon the display server, ScreenCaptureKit, and Metal all share the same unified memory pool, making this effectively free.

**Trade-offs:** Texture lifetime is tied to the `CVMetalTexture` wrapper. Must retain the `CVMetalTexture` alongside the `MTLTexture` or the IOSurface backing can be reclaimed. Call `CVMetalTextureCacheFlush` periodically to release stale entries.

```swift
// Capture/CaptureManager.swift (sketch)
func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .screen,
          let imageBuffer = CMSampleBufferGetImageBuffer(buffer) else { return }

    var cvTexture: CVMetalTexture?
    let w = CVPixelBufferGetWidth(imageBuffer)
    let h = CVPixelBufferGetHeight(imageBuffer)
    CVMetalTextureCacheCreateTextureFromImage(
        nil, textureCache, imageBuffer, nil, .bgra8Unorm, w, h, 0, &cvTexture)

    if let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) {
        texturePool.write(texture, slot: slotIndex)
        // Retain cvTexture alongside texture so IOSurface stays alive
        retainedCVTextures[slotIndex] = cvTexture
    }
}
```

### Pattern 4: Single-Pass Stereo via Metal Viewport Array

**What:** Render both eyes in one draw call using `setViewports([leftVP, rightVP])` on the `MTLRenderCommandEncoder`. The vertex shader uses `[[viewport_array_index]]` to route each instance to the correct half of the output texture. Left eye at x=0, right eye at x=width/2. Output is a single wide texture that maps to the Viture side-by-side display.

**When to use:** Always for stereo. Two separate render passes are ~2x the GPU cost. Single-pass instancing with viewport array costs almost nothing extra.

**Trade-offs:** Vertex shader must include `[[viewport_array_index]]` as an output attribute. Metal requires the GPU family to support multiple viewports (all Apple Silicon and modern AMD/Intel on macOS do). Geometry amplification (visionOS variant) is not needed here — simple instancing with `[[instance_id]]` suffices.

```metal
// Render/Shaders.metal
struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
    uint   viewportIndex [[viewport_array_index]];
};

vertex VertexOut stereoVertex(
    uint instanceID [[instance_id]],   // 0 = left eye, 1 = right eye
    uint vertexID   [[vertex_id]],
    constant Uniforms &uniforms [[buffer(0)]])
{
    VertexOut out;
    float4x4 viewProj = (instanceID == 0) ? uniforms.leftViewProj : uniforms.rightViewProj;
    out.position      = viewProj * quadPosition(vertexID);
    out.texCoord      = quadTexCoord(vertexID);
    out.viewportIndex = instanceID;
    return out;
}
```

---

## Data Flow

### Primary Frame Path: Capture → Texture → Render → Display

```
[macOS Window Server]
        │ IOSurface (shared GPU memory)
        ▼
[SCStream callback]  ← arrives on CaptureManager's private DispatchQueue
        │
        │ CMSampleBuffer → CVImageBuffer (IOSurface-backed)
        ▼
[CVMetalTextureCacheCreateTextureFromImage]
        │ zero-copy: MTLTexture wraps same IOSurface
        ▼
[TexturePool.write(texture, slot:)]  ← NSLock atomic swap
        │
        │  (next MTKView vsync tick)
        ▼
[RenderEngine.draw(in: MTKView)]  ← runs on main/render queue via CAMetalDisplayLink
        │
        │ TexturePool.read(slot:) → MTLTexture for each monitor
        │ TrackingProvider.latestPose → HeadPose
        │ VirtualMonitorLayout → world-space quad positions
        ▼
[StereoCamera]
        │ HeadPose.orientation → view rotation matrix (inverse quaternion)
        │ HeadPose.position    → translation (zero for 3DOF, real for 6DOF)
        │ Per-eye IPD offset   → separate left/right view matrices
        ▼
[MTLRenderCommandEncoder]
        │ setViewports([leftVP, rightVP])
        │ setVertexBytes(Uniforms: leftViewProj, rightViewProj, quadTransform)
        │ setFragmentTexture(monitorTexture, index: 0)
        │ drawPrimitives(.triangleStrip, instanceCount: 2)  ← one call per quad
        ▼
[MTLDrawable → present]
        │
        ▼
[Viture Luma Ultra display — side-by-side stereo]
```

### Head Pose Flow (parallel, asynchronous)

```
[Viture macOS SDK IMU callback]  ← arrives on SDK's private thread
        │
        │ raw quaternion / Euler angles
        ▼
[VitureTracker.onPoseUpdate(HeadPose)]
        │ captured by AppCoordinator closure
        ▼
[RenderEngine.latestPose = pose]  ← single atomic store (nonisolated var or actor)
        │
        (render loop reads this value each frame — always a consistent struct copy)
```

### Key Data Flows

1. **Texture update:** SCStream callback thread → TexturePool (NSLock swap) → render thread reads on next vsync. No blocking of either thread.
2. **Pose update:** SDK IMU thread → atomic HeadPose store → render thread reads struct copy on next vsync. HeadPose is a value type; no aliasing issues.
3. **Layout change:** User picks new window → WindowManager rebuilds SCFilter → CaptureManager restarts SCStream → new textures start arriving. RenderEngine layout is updated on main queue before restart completes.

---

## Component Boundaries: What Talks to What

```
AppCoordinator
    ├── creates and starts: CaptureManager, VitureTracker, RenderEngine
    ├── injects: texturePool into both CaptureManager and RenderEngine
    ├── injects: TrackingProvider into RenderEngine
    └── injects: VirtualMonitorLayout into RenderEngine

CaptureManager
    → writes to: TexturePool
    ← receives from: WindowManager (SCFilter configuration)
    ✗ never touches: RenderEngine, TrackingProvider

TrackingProvider (VitureTracker)
    → calls: onPoseUpdate closure (AppCoordinator registers this)
    ✗ never touches: CaptureManager, RenderEngine directly

RenderEngine
    → reads from: TexturePool, TrackingProvider.latestPose, VirtualMonitorLayout
    → drives: MTKView via MTKViewDelegate
    ✗ never touches: CaptureManager, Viture SDK
```

**Rule:** Data flows through value types (HeadPose struct, MTLTexture reference copied by value into TexturePool) or through the TexturePool intermediary. No component holds a direct reference to another's internals.

---

## Thread Safety Architecture

### Three Concurrent Producers/Consumers

| Thread | Owner | What it Does |
|--------|-------|--------------|
| Main queue | AppCoordinator, WindowManager | Setup, teardown, layout changes |
| Capture queue (private) | CaptureManager / SCStream | SCStream callbacks → texture upload |
| Render queue (display-link) | RenderEngine / MTKView | Reads textures + pose, encodes GPU commands |
| SDK IMU thread (SDK-private) | VitureTracker | Delivers HeadPose callbacks |

### Synchronization Rules

1. **TexturePool writes** (capture queue) and **reads** (render queue) are protected by `NSLock`. The critical section is two pointer assignments — microseconds.

2. **HeadPose** is a Swift struct (value type). `RenderEngine` holds `var latestPose: HeadPose` as a property. `VitureTracker` writes it via a closure captured by `AppCoordinator`, which dispatches to the render queue (`DispatchQueue.main.async` or directly to RenderEngine's actor). This ensures the render loop always reads a complete struct — no partial writes.

3. **SCStream callbacks arrive on the queue passed to `addStreamOutput(_:type:sampleHandlerQueue:)`**. Use a dedicated serial `DispatchQueue` (not `.main`) so capture processing never blocks the UI. The callback must complete quickly — do only the CVMetalTextureCache lookup and TexturePool write, then return.

4. **GPU / CPU synchronization:** MTKView's triple-buffering semaphore (capacity 3) prevents the CPU from recycling a `MTLTexture` while the GPU is still reading it. The retained `CVMetalTexture` array in CaptureManager should be sized to match the in-flight frame count (3) to prevent IOSurface reclamation mid-render.

5. **SCStream restart** (window change): Perform on the main queue. Stop the old stream, update the SCFilter, start a new stream. RenderEngine continues drawing with the last-valid textures from TexturePool until new ones arrive — no crash, slight frame staleness acceptable.

### Tearing Prevention

SCStream delivers frames at the source display's refresh rate (typically 60 Hz ProMotion, up to 120 Hz). The Metal render loop runs at the Viture display's rate (90 Hz, confirm from SDK docs). These rates may not align. The TexturePool single-slot-per-monitor design means the render loop always picks up the **latest** captured frame, skipping intermediate frames if the render rate is slower, and repeating the last frame if capture lags. This is the correct trade-off: skip > stale, repeat > crash.

---

## 6DOF Extensibility Strategy

The entire tracking abstraction exists specifically for this transition. Adding 6DOF in v2 requires:

1. Create `SixDOFTracker: TrackingProvider` in `Tracking/SixDOFTracker.swift`.
2. In `AppCoordinator`, swap the injected `TrackingProvider` instance from `VitureTracker` to `SixDOFTracker`.
3. Populate `HeadPose.position` with the positional offset from the 6DOF source.
4. `StereoCamera` already uses `HeadPose.position` in the view matrix translation — no render-layer change.

**Zero changes to:** CaptureManager, RenderEngine, Shaders.metal, TexturePool.

The `StereoCamera` view matrix construction must be written from day one to include `HeadPose.position` in the translation component, even when it is always `SIMD3<Float>.zero`. This avoids a shader/matrix change later.

```swift
// Render/StereoCamera.swift
func viewMatrix(for eye: Eye, pose: HeadPose, layout: VirtualMonitorLayout) -> float4x4 {
    let rotation    = float4x4(pose.orientation.inverse)   // rotate world around head
    let translation = float4x4(translation: -pose.position) // zero for 3DOF
    let eyeOffset   = float4x4(translation: eye.ipd(layout)) // left/right separation
    return eyeOffset * rotation * translation
}
```

---

## Build Order (What Must Exist Before What)

```
Phase 1 — Foundation
  1a. TrackingProvider protocol + HeadPose struct  (no dependencies)
  1b. VirtualMonitorLayout value type               (no dependencies)
  1c. TexturePool                                   (no dependencies)

Phase 2 — Capture Pipeline
  2a. PermissionGateway                             (needs: Foundation)
  2b. CaptureManager (SCStream + CVMetalTextureCache → TexturePool)
                                                    (needs: TexturePool, PermissionGateway)

Phase 3 — Render Pipeline (can parallel with Phase 2)
  3a. Metal pipeline state + Shaders.metal (stereo viewport array, textured quad)
  3b. QuadMesh vertex buffers
  3c. StereoCamera (view + projection matrices from HeadPose)
  3d. RenderEngine (MTKViewDelegate, reads TexturePool + pose)
                                                    (needs: 3a, 3b, 3c, TexturePool)

Phase 4 — Tracking
  4a. VitureTracker (Viture macOS SDK IMU callback → HeadPose)
                                                    (needs: TrackingProvider protocol)

Phase 5 — Integration
  5a. AppCoordinator (wires 2b, 3d, 4a; injects texturePool)
  5b. WindowManager (SCShareableContent picker)
  5c. End-to-end smoke test: two live windows, head rotation, stereo output

Phase 6 (v2) — 6DOF
  6a. SixDOFTracker conforms to TrackingProvider    (needs: TrackingProvider protocol only)
  6b. AppCoordinator swap: VitureTracker → SixDOFTracker
```

**Critical path:** TexturePool → CaptureManager AND RenderEngine → AppCoordinator integration. TrackingProvider protocol is a prerequisite for RenderEngine's StereoCamera (the interface must be defined before the camera can accept a pose), but the concrete VitureTracker can be stubbed with a mock during render development.

---

## Anti-Patterns

### Anti-Pattern 1: Texture Upload on Main Thread

**What people do:** Convert CMSampleBuffer to MTLTexture inside a `DispatchQueue.main.async` block to avoid threading complexity.
**Why it's wrong:** Blocks the UI. At 60 fps, a frame arrives every 16.7 ms. Any main-thread work competes with AppKit event handling and layout. SCStream callbacks on a dedicated queue eliminate this entirely.
**Do this instead:** Pass a dedicated serial `DispatchQueue` to `addStreamOutput(_:type:sampleHandlerQueue:)` and do all texture work there.

### Anti-Pattern 2: Sharing MTLTexture Without Retaining CVMetalTexture

**What people do:** Extract `MTLTexture` from `CVMetalTextureCacheCreateTextureFromImage`, store only the `MTLTexture`, and let the `CVMetalTexture` wrapper go out of scope.
**Why it's wrong:** Releasing the `CVMetalTexture` wrapper can allow ScreenCaptureKit to reclaim the backing IOSurface. The MTLTexture pointer remains valid but the GPU may read garbage data mid-frame.
**Do this instead:** Keep a `[CVMetalTexture?]` array (sized to in-flight count, typically 3) alongside the `[MTLTexture?]` array. Replace both together.

### Anti-Pattern 3: Per-Frame Pipeline State Creation

**What people do:** Create `MTLRenderPipelineState` inside the draw callback to handle dynamic configuration changes.
**Why it's wrong:** Pipeline state compilation is expensive (100–500 ms). Even if cached by Metal, the synchronization overhead of checking a cache mid-frame adds jitter.
**Do this instead:** Create all pipeline states at startup in `RenderEngine.setup()`. Use uniform buffers to pass per-frame parameters (textures, matrices). If display configuration changes, rebuild pipeline off the render loop thread and swap atomically.

### Anti-Pattern 4: Leaking ScreenCaptureKit Types into the Render Layer

**What people do:** Pass `SCWindow`, `SCStream`, or `CMSampleBuffer` directly to RenderEngine for it to process.
**Why it's wrong:** Couples the render layer to the capture API. Breaks the 6DOF extensibility goal. Makes unit testing the render pipeline impossible without mocking SCK.
**Do this instead:** CaptureManager resolves all SCK types to plain `MTLTexture` references before passing anything to the render layer. The render layer only speaks Metal.

### Anti-Pattern 5: Hard-Coding 3DOF Assumptions into StereoCamera

**What people do:** Build the view matrix as `float4x4(pose.orientation.inverse)` without a translation component, because "we don't have positional tracking yet."
**Why it's wrong:** Adding 6DOF later requires changing the shader/matrix code, risking regression in the 3DOF path.
**Do this instead:** Always include `HeadPose.position` in the translation term from day one. When position is `.zero`, the matrix is mathematically identical to the 3DOF case. Zero cost, full extensibility.

---

## Integration Points

### External Services

| Service | Integration Pattern | Notes |
|---------|---------------------|-------|
| ScreenCaptureKit | SCStream with `SCStreamOutput` delegate | Requires screen-recording permission; permission request is one-shot and must precede stream creation |
| Viture macOS SDK | C/ObjC callback bridge or Swift wrapper, IMU quaternion | SDK is a separate download from the Unity SDK. Callback fires on SDK-internal thread — marshal to value type immediately |
| Metal | MTLDevice → MTLCommandQueue → MTKViewDelegate draw cycle | Single device shared across CaptureManager (texture cache) and RenderEngine |
| IOSurface / CoreVideo | CVMetalTextureCache bridges SCK output to Metal | MTLDevice must be the same instance used for the cache and the render encoder |

### Internal Boundaries

| Boundary | Communication | Notes |
|----------|---------------|-------|
| CaptureManager → RenderEngine | TexturePool (NSLock, value swap) | No direct reference; AppCoordinator injects shared pool |
| VitureTracker → RenderEngine | Closure → atomic HeadPose store | HeadPose is a struct; copy on write semantics |
| WindowManager → CaptureManager | SCFilter rebuild, method call on main queue | Trigger stream restart; RenderEngine stale-frames during gap |
| AppCoordinator → all | Owns and starts/stops all components | Single coordinator, no event bus |

---

## Sources

- [ScreenCaptureKit SCStream — addStreamOutput, sampleHandlerQueue](https://developer.apple.com/documentation/screencapturekit/scstream/3928168-addstreamoutput) — HIGH confidence
- [CVMetalTextureCache — Apple Developer Documentation](https://developer.apple.com/documentation/corevideo/cvmetaltexturecache-q3j) — HIGH confidence
- [Rendering to multiple viewports in a draw command — Metal](https://developer.apple.com/documentation/metal/mtlrendercommandencoder/rendering_to_multiple_viewports_in_a_draw_command) — HIGH confidence
- [Rendering macOS in Virtual Reality — Oskar Groth](https://oskargroth.com/blog/rendering-macos-in-vr) — MEDIUM confidence (pre-ScreenCaptureKit era; stereo instancing pattern remains valid)
- [Metal Camera Tutorial Part 2: CVPixelBuffer to Metal Texture](https://navoshta.com/metal-camera-part-2-metal-texture/) — MEDIUM confidence (iOS-focused, pattern identical on macOS)
- [VITURE XR Glasses SDK — macOS platform listing](https://www.viture.com/developer) — MEDIUM confidence (confirmed macOS SDK exists; internal API shape requires inspection of downloaded SDK)
- [Swift concurrency and Metal — Swift Forums](https://forums.swift.org/t/swift-concurrency-and-metal/71908) — MEDIUM confidence (threading patterns)
- [CADisplayLink / CAMetalDisplayLink — Apple Developer Documentation](https://developer.apple.com/documentation/quartzcore/cadisplaylink) — HIGH confidence

---

*Architecture research for: macOS XR virtual desktop (Viture Luma Ultra)*
*Researched: 2026-04-14*
