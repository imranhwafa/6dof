# Project Research Summary

**Project:** Viture Luma Ultra macOS XR Virtual Desktop
**Domain:** Native macOS XR virtual desktop — window capture, stereo rendering, world-locked spatial monitors
**Researched:** 2026-04-14
**Confidence:** MEDIUM (Apple APIs HIGH; Viture macOS SDK MEDIUM/LOW pending direct access)

---

## Executive Summary

This is a native macOS productivity app that captures live window content and renders it as world-locked virtual monitors inside Viture Luma Ultra XR glasses. The canonical implementation stack is Swift + Metal + ScreenCaptureKit with no third-party rendering frameworks. Metal handles the stereo pipeline directly via viewport arrays; ScreenCaptureKit provides zero-copy IOSurface-backed frame delivery; the Viture macOS SDK (a C-only binary library, not the Unity SDK) supplies per-frame head orientation via a polling API on the Carina tracking chip. The core rendering loop is: capture window → wrap IOSurface as MTLTexture (zero-copy) → poll head pose → compute per-eye view matrices → single-pass stereo draw to 3840×1080 side-by-side framebuffer → present to Viture display.

The recommended architecture is a clean five-layer decomposition: `AppCoordinator` (wiring) → `CaptureManager` (SCStream + TexturePool) → `VitureTracker` via `TrackingProvider` protocol (pose) → `RenderEngine` (Metal stereo draw) → `VirtualMonitorLayout` (pure value type). The protocol-backed tracking layer is the single most important architectural decision: it enables 6DOF to be dropped in as a v2 conformer with zero changes to the render or capture layers. The `HeadPose` struct must carry a `SIMD3<Float>` position field from day one even though v1 populates it with `.zero`.

The dominant risk is the Viture macOS SDK. Its exact macOS version requirement (likely Sequoia 15+), data quality (SDK-internal sensor fusion vs. raw IMU), and coordinate axis conventions must be verified empirically before building the render pipeline on top of it. The second systemic risk is ScreenCaptureKit's IOSurface pool exhaustion (`-3821` disconnection) which silently kills the stream if sample buffers are held too long — triple-buffer blitting must be established in Phase 1, not deferred. If either of these foundations is unstable, every feature built on top fails.

---

## Key Findings

### Recommended Stack

The entire stack is Apple-native with one external dependency (Viture SDK). No third-party rendering engines, no SPM packages, no CocoaPods. Metal gives direct `MTLRenderCommandEncoder` control required for custom stereo viewport splitting; ScreenCaptureKit provides the only modern, non-deprecated window capture API on macOS; AppKit (not SwiftUI) owns the app lifecycle and the fullscreen window on the Viture NSScreen. The Viture SDK is a manually linked C binary (`libglasses.dylib`, arm64) bridged via a Swift bridging header — it cannot be distributed via SPM or CocoaPods, and no Swift wrapper is shipped by Viture.

**CRITICAL flag:** The Viture macOS SDK may require macOS Sequoia (15+). This must be verified before committing to a deployment target. If true, it raises the minimum from the otherwise-preferred macOS 13 to 15.

**Core technologies:**
- **Swift 5.10 / Xcode 16:** Primary language — only practical choice for native macOS
- **Metal + MetalKit (MTKView):** Stereo render pipeline — only API with direct viewport-array control; OpenGL is deprecated, SceneKit and RealityKit both take over the render loop
- **ScreenCaptureKit (macOS 13+):** Live window capture — zero-copy IOSurface output, replaces all deprecated alternatives (`CGWindowListCreateImage`, `CGDisplayStream`)
- **CoreVideo (CVMetalTextureCache):** Zero-copy IOSurface → MTLTexture bridge — eliminates CPU copy on every frame; requires `storageMode = .shared` on macOS 13+
- **Viture XR Glasses SDK (C API):** Head pose delivery — polling API (`xr_device_provider_get_gl_pose_carina`) returns 7 floats `[px, py, pz, qw, qx, qy, qz]`; macOS arm64 binary only
- **simd (stdlib):** Matrix and quaternion math — zero-overhead, no third-party math library needed
- **AppKit (NSApplication, NSWindow, NSScreen):** Display detection and fullscreen window management — identify Viture screen by `CGDirectDisplayID`, create borderless window at 3840×1080

### Expected Features

The product's entire value proposition collapses if world-locked monitors are unstable. Tracking quality is the highest-risk dependency, not the render pipeline.

**Must have (table stakes — v1):**
- Live window/screen capture via ScreenCaptureKit — without this there is nothing to display
- Correct stereo output (side-by-side 3840×1080) — mono output is broken immediately
- World-locked monitor transform driven by Viture 3DOF orientation — the core value proposition
- Stable, low-drift head tracking — unusable within minutes if this fails
- Re-centering keyboard shortcut (e.g., Cmd+R) — escape hatch when drift accumulates
- Two Metal-rendered textured quads (two monitors) — the product is a workspace, not a mirror
- Screen Recording permission prompt with graceful denial handling — required by macOS TCC
- Readable text quality (high-res capture, at least 1080p per quad) — if text is blurry the core use case fails

**Should have (competitive differentiators — v1.x):**
- Per-window capture via `SCWindowFilter` (not full-display mirror) — privacy and multi-Space flexibility
- Smooth follow / auto-recenter on large drift (slerp toward view center) — comfort for long sessions
- Configurable monitor size and distance — users have strong preferences
- Persistent monitor positions across sessions — daily-driver quality
- Native menu bar app (NSStatusItem, no dock icon) — expected for a background utility

**Defer (v2+):**
- Click-through spatial cursor — requires full raycast + synthetic mouse event input system; explicitly out of v1 scope
- 6DOF positional tracking — architecture is protocol-ready; needs validated Viture positional SDK
- Multi-Space / per-app dynamic assignment — high complexity, low v1 value
- Spatial audio — orthogonal to core visual fidelity

### Architecture Approach

The architecture is a strict pipeline with no cross-layer coupling. `CaptureManager` only speaks ScreenCaptureKit and Metal textures; `RenderEngine` only speaks Metal and value types; `VitureTracker` only speaks the Viture C SDK and the `TrackingProvider` protocol. `AppCoordinator` is the only object that holds references to multiple layers and wires them together at startup. This strict boundary is not overhead — it directly enables 6DOF to be added in v2 by swapping one conformer without touching any other file.

**Major components:**
1. `AppCoordinator` — wires all subsystems, owns lifetimes, injects shared TexturePool
2. `CaptureManager` — SCStream per monitor slot, CVMetalTextureCache, publishes MTLTexture[2] to TexturePool
3. `TexturePool` — NSLock-protected atomic swap; decouples capture queue from render queue
4. `TrackingProvider` (protocol) + `VitureTracker` (concrete) — delivers `HeadPose` struct on SDK callback thread
5. `RenderEngine` — MTKViewDelegate, reads TexturePool + HeadPose, encodes single-pass stereo draw
6. `StereoCamera` — computes per-eye view/projection matrices from HeadPose + VirtualMonitorLayout; includes `pose.position` translation from day one
7. `VirtualMonitorLayout` — pure value type; world-space quad anchors, sizes, IPD; serializable
8. `PermissionGateway` — gates startup on Screen Recording TCC; never called before main window is visible

### Critical Pitfalls

1. **SCStream output delegate silently deallocated** — SCStream holds a *weak* reference to the output conformer. If declared locally it is collected before any frame arrives; no error is raised. Prevention: make `CaptureManager` itself conform to `SCStreamOutput` and pass `self`. Address in Phase 1 before any other capture work.

2. **IOSurface pool exhaustion causing -3821 silent stream disconnection** — Holding `CMSampleBuffer` or derived `MTLTexture` across frame boundaries exhausts the fixed pool (default depth 3) at 60fps. SCK disconnects the stream entirely. Prevention: triple-buffer blit into owned textures in `captureOutput`, release sample buffer immediately, set `queueDepth = 5`. Non-negotiable architecture, not an optimization. Implement in Phase 1.

3. **Viture SDK coordinate axis mismatch** — SDK may return orientation in a convention not matching Metal's right-handed Y-up system. Applying the quaternion directly without axis verification produces inverted or swapped motion. Prevention: axis diagnostic — print raw SDK values while rotating on each physical axis individually before writing any rendering code that consumes pose data. Address at the start of Phase 3.

4. **Capture-to-pose-to-render latency triangle causes world drift** — If head pose is sampled at the top of the frame event loop rather than immediately before encoding draw calls, the view matrix is one full frame stale. At moderate head speed (90°/sec) this is ~2° of drift per frame — visibly swimming. Prevention: sample pose as late as possible in Metal command buffer encoding sequence. Address in Phase 3.

5. **macOS Sequoia weekly screen recording re-authorization** — macOS 15 prompts users to re-approve Screen Recording approximately monthly. The `Persistent Content Capture` entitlement can exempt the app but requires Apple approval. Prevention: apply for entitlement early; design permission UX for periodic re-prompts; do not assume permission state is permanent across reboots. Address before distribution.

---

## Implications for Roadmap

Based on dependency ordering in the architecture research and pitfall phase mapping, five phases are recommended.

### Phase 1: Capture Foundation

**Rationale:** Every other phase depends on reliable frame delivery from ScreenCaptureKit. The two most dangerous pitfalls (weak delegate and -3821 pool exhaustion) must be solved before any render code is written against them. Permission flow must precede stream creation.

**Delivers:** `CaptureManager` reliably delivering `MTLTexture` references from live windows into a `TexturePool` at 60fps for at least 10 minutes under sustained load with no -3821 errors. Screen Recording permission flow complete and tested on a clean account. `NSScreenCaptureUsageDescription` in `Info.plist`.

**Addresses (from FEATURES.md):** Live window capture, Screen Recording permission flow, readable text quality (high-res capture configuration).

**Avoids (from PITFALLS.md):** SCStream output delegate deallocation (Pitfall 1), IOSurface pool exhaustion (Pitfall 2), permission dialog on main thread at launch (Pitfall 3), missing Info.plist key (Pitfall 5).

**Stack used:** ScreenCaptureKit, CoreVideo (CVMetalTextureCache), AppKit (PermissionGateway), NSLock (TexturePool).

### Phase 2: Stereo Render Pipeline

**Rationale:** The render pipeline can be developed against static test textures with no live capture and no real tracking. Validating stereo correctness independently avoids debugging two systems simultaneously — a significant advantage given the optical complexity.

**Delivers:** `RenderEngine` rendering two textured quads in correct side-by-side stereo at 60fps to the Viture 3840×1080 display, with asymmetric frustum projection, correct per-eye IPD offset, and stable frame pacing on a multi-display Mac. Test textures acceptable for validation; Phase 1 live textures integrated at end of phase.

**Addresses (from FEATURES.md):** Correct stereo output, two visible monitor quads, default monitor placement.

**Avoids (from PITFALLS.md):** Symmetric projection matrices (Pitfall 6), single viewport for both eyes (Pitfall 7), depth buffer not cleared (Pitfall 8), CAMetalLayer frame pacing stutter on multi-monitor systems (Pitfall 12).

**Stack used:** Metal (MTLRenderCommandEncoder, MTLRenderPipelineState, viewport array), MetalKit (MTKView), simd, AppKit (NSScreen detection, NSWindow fullscreen on Viture display).

### Phase 3: Head Tracking and World-Lock

**Rationale:** Tracking cannot be validated until both the Viture SDK axis conventions and the render pipeline are independently confirmed correct. Mixing these concerns makes bugs indistinguishable. This phase also resolves the project's highest unknown: SDK data quality and coordinate convention.

**Delivers:** `VitureTracker` delivering verified `HeadPose` values at >= 60Hz. `StereoCamera` consuming `HeadPose` with `position` field included from day one. World-locked quad transform inverse-rotating with head motion. Re-centering keyboard shortcut. Pose sampled late in encoder sequence (latency triangle discipline established).

**Addresses (from FEATURES.md):** World-locked monitors, stable low-drift tracking, re-centering hotkey.

**Avoids (from PITFALLS.md):** Viture SDK coordinate axis mismatch (Pitfall 9) — axis diagnostic before render integration; SDK callbacks mutating Metal state unsafely (Pitfall 10); latency triangle drift (Pitfall 11).

**Stack used:** Viture macOS SDK (C API via Swift bridging header), simd (quaternion-to-matrix), NSLock or os_unfair_lock (HeadPose atomic store).

**Research flag: HIGH — run axis diagnostic empirically on hardware before any render integration. Confirm SDK macOS version requirement before starting this phase.**

### Phase 4: Integration and End-to-End Validation

**Rationale:** `AppCoordinator` wiring is a distinct phase because it can only be written after Capture, Render, and Tracking layers have stable, tested APIs. Wiring before layers are settled produces coupling churn.

**Delivers:** `AppCoordinator` wiring all layers. Two live windows captured and displayed as world-locked stereo monitors. Window picker UI (`WindowManager`). End-to-end test at 60fps for 10 minutes: no -3821, no drift accumulation > 1°/min, text readable.

**Addresses (from FEATURES.md):** All v1 table stakes verified together end-to-end for the first time.

**Avoids (from PITFALLS.md):** SCK types leaking into the render layer (Architecture anti-pattern 4 from ARCHITECTURE.md).

### Phase 5: Polish and Distribution

**Rationale:** Distribution concerns (Sequoia entitlement, macOS permission UX, menu bar integration) are intentionally last. They depend on a stable app to wrap and the entitlement application requires a working build to submit.

**Delivers:** NSStatusItem menu bar app (no dock icon). Persistent monitor position storage (UserDefaults). Sequoia Persistent Content Capture entitlement submitted. Stream-interrupted UX (`-3821` surfaced to user with reconnect affordance). Notarized build verified on a clean account.

**Addresses (from FEATURES.md):** Native menu bar app, persistent positions, graceful stream error handling.

**Avoids (from PITFALLS.md):** Sequoia weekly re-authorization disruption (Pitfall 4), UX pitfall of silent stream failure with no recovery affordance.

---

### Phase Ordering Rationale

- Capture before render: Pitfalls 1 and 2 (delegate deallocation, -3821 pool exhaustion) live in the capture layer and must be resolved before the render layer builds on top of them.
- Render before tracking: stereo correctness and tracking correctness are independent concerns; mixing them makes bugs indistinguishable from each other.
- Tracking after render: the axis diagnostic requires a trusted display pipeline — you need a known-good renderer to verify that SDK quaternions are producing correct visual output.
- Integration after individual layers: `AppCoordinator` wiring is straightforward once each layer has a stable API. Wiring before layers stabilize produces coupling churn.
- Polish last: distribution concerns block on a working product; Sequoia entitlement application requires a build; menu bar integration is pure polish, not capability.

### Research Flags

**Needs deeper research or empirical validation during planning:**
- **Phase 3 (Head Tracking):** Viture macOS SDK coordinate axes must be verified empirically with hardware. SDK documentation for the macOS Carina polling API is thin. Also must confirm whether macOS Sequoia (15+) is a hard requirement — this changes the deployment target for the whole project.
- **Phase 3 (Head Tracking):** SDK polling rate and sensor fusion quality are unknown quantities. If delivered orientation has >2°/min drift without app-side filtering, a complementary filter layer becomes first-class architecture, not an afterthought.
- **Phase 5 (Distribution):** Persistent Content Capture entitlement approval process and timeline are underdocumented for third-party tools.

**Standard patterns (skip research-phase):**
- **Phase 1 (Capture):** ScreenCaptureKit is thoroughly documented in WWDC22/23/24 sessions. IOSurface zero-copy path, permission flow, and -3821 recovery are all well-documented with community validation.
- **Phase 2 (Stereo Render):** Metal multi-viewport stereo, MTKView setup, and asymmetric frustum projection are established patterns with high-confidence sources.
- **Phase 4 (Integration):** AppCoordinator wiring follows directly from the architecture's explicit build-order dependency graph.

---

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | MEDIUM | Apple APIs (Metal, ScreenCaptureKit, CoreVideo) HIGH. Viture macOS SDK MEDIUM — C API confirmed, macOS arm64 confirmed, but Swift wrapper absent, macOS version floor (Sequoia?) unverified, no public GitHub. |
| Features | MEDIUM | Table stakes and competitor analysis derived from Breezy Desktop source and Immersed/Virtual Desktop docs — HIGH for the pattern, LOW for Viture-specific SDK capabilities (IMU quality, polling rate). |
| Architecture | HIGH | All patterns based on well-documented Apple APIs. Protocol-backed TrackingProvider and TexturePool patterns verified against Metal + SCK threading models. Only Viture SDK callback behavior is MEDIUM. |
| Pitfalls | MEDIUM | ScreenCaptureKit and Metal pitfalls HIGH (official docs + WWDC + community implementations). Viture coordinate axis conventions LOW — empirical verification required. Sequoia entitlement situation MEDIUM. |

**Overall confidence:** MEDIUM

### Gaps to Address

- **Viture macOS SDK minimum OS requirement:** Must verify whether macOS Sequoia (15+) is required before setting the deployment target. Directly determines the addressable install base and build settings for the entire project.
- **Viture SDK IMU data quality and polling rate:** The quality of world-lock depends entirely on this. If raw IMU data has unacceptable drift, a complementary filter must be added as first-class architecture in Phase 3. Validate empirically before any world-lock feature work.
- **Viture SDK coordinate axis convention:** Cannot be determined from documentation alone. Must rotate device on each axis empirically and map SDK output to Metal conventions before writing any view matrix code.
- **Barrel distortion correction requirement:** Whether the Viture Luma Ultra requires lens distortion correction is unconfirmed. If the display optics require it, a post-processing pass must be added to the render pipeline. Check Viture optical spec sheet before completing Phase 2.
- **Viture display actual refresh rate:** Cited as 90Hz in research but unconfirmed from primary source. MTKView `preferredFramesPerSecond` and `CAMetalDisplayLink` target must match the actual display refresh rate. Confirm from hardware spec before Phase 2.

---

## Sources

### Primary (HIGH confidence)
- [Apple Developer — ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit/) — SCStream, SCStreamConfiguration, SCContentFilter API
- [WWDC22 — Meet ScreenCaptureKit](https://developer.apple.com/videos/play/wwdc2022/10156/) — frame delivery, IOSurface, configuration
- [WWDC23 — What's new in ScreenCaptureKit](https://developer.apple.com/videos/play/wwdc2023/10136/) — SCContentSharingPicker, pixel formats
- [WWDC24 — Capture HDR content with ScreenCaptureKit](https://developer.apple.com/videos/play/wwdc2024/10088/) — HDR, dynamic range
- [Apple Developer — MTLDevice.makeTexture(descriptor:iosurface:plane:)](https://developer.apple.com/documentation/metal/mtldevice/maketexture(descriptor:iosurface:plane:)) — IOSurface zero-copy Metal texture
- [Apple Developer — MTLRenderCommandEncoder.setViewports](https://developer.apple.com/documentation/metal/mtlrendercommandencoder/2869738-setviewports) — multi-viewport stereo
- [Apple Developer Forums — SCStream weak output reference](https://developer.apple.com/forums/thread/733077) — Pitfall 1 (delegate deallocation) confirmed
- [Apple Developer — SCStreamConfiguration.queueDepth](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/queuedepth) — pool exhaustion behavior

### Secondary (MEDIUM confidence)
- [Viture XR Glasses SDK documentation](https://www.viture.com/developer/glasses-sdk/glasses) — C API surface, macOS arm64, Carina polling API, 7-float pose format
- [Oskar Groth — Rendering macOS in VR](https://oskargroth.com/blog/rendering-macos-in-vr) — IOSurface zero-copy + instanced stereo viewport in practice
- [fatbobman.com — ScreenSage architecture](https://fatbobman.com/en/posts/screensage-from-pixel-to-meta/) — -3821 disconnection, static frame UX pitfall
- [Michael Tsai — Sequoia Screen Recording Prompts](https://mjtsai.com/blog/2024/08/08/sequoia-screen-recording-prompts-and-the-persistent-content-capture-entitlement/) — Persistent Content Capture entitlement
- [Breezy Desktop README](https://github.com/wheaney/breezy-desktop) — feature set, re-centering, Smooth Follow behavior
- [EasyVXR (community Viture wrapper)](https://github.com/Wojtekb30/EasyVXR) — IMU struct reference, Euler angle output format

### Tertiary (LOW confidence — needs validation)
- Viture Luma Ultra optical spec (FOV ~42° per eye, IPD ~64mm) — unverified from primary source; confirm from hardware spec before Phase 2
- Viture macOS SDK macOS version floor (Sequoia 15+ likely) — inferred from SDK docs; must confirm before deployment target decision
- Viture display refresh rate (90Hz cited) — unconfirmed; check hardware spec before MTKView configuration

---

*Research completed: 2026-04-14*
*Ready for roadmap: yes*
