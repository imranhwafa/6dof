# Pitfalls Research

**Domain:** macOS XR virtual desktop — ScreenCaptureKit + Metal stereo rendering + Viture macOS SDK
**Researched:** 2026-04-14
**Confidence:** MEDIUM (ScreenCaptureKit and Metal patterns HIGH; Viture macOS SDK coordinate specifics LOW due to inaccessible official docs)

---

## Critical Pitfalls

### Pitfall 1: SCStream Output Object Collected Before First Frame

**What goes wrong:**
`SCStream` holds a **weak reference** to its `SCStreamOutput` delegate. If the output object is declared locally (e.g., inside a setup function), it is deallocated before any frame arrives. The stream silently drops every frame with no error — `captureOutput(_:didOutputSampleBuffer:of:)` is never called.

**Why it happens:**
The API accepts an `SCStreamOutput` protocol conformer, but the caller owns the reference. Nothing in the compiler or runtime warns you. The symptom is indistinguishable from a misconfigured filter or a permissions failure.

**How to avoid:**
Hold the `SCStreamOutput` conformer as a strong `var` on a long-lived object (e.g., the capture manager class itself). The simplest pattern: make your capture manager class conform to `SCStreamOutput` and pass `self` to `addStreamOutput(_:type:sampleHandlerQueue:)`.

**Warning signs:**
- `startCapture()` completes without error but `captureOutput` is never called
- No frame drop errors in console
- Restarting the stream appears to "fix" it intermittently (object survives slightly longer in some runs)

**Phase to address:** Capture layer foundation (Phase 1)

---

### Pitfall 2: IOSurface Surface Pool Exhaustion Causing Silent -3821 Disconnection

**What goes wrong:**
ScreenCaptureKit maintains a fixed pool of IOSurface-backed frame buffers. The pool size is `queueDepth` (default: 3, max: 8). If your `captureOutput` callback holds a reference to the `CMSampleBuffer` — or any texture derived from it — longer than `minimumFrameInterval × (queueDepth - 1)`, the pool runs out of surfaces. SCK does not degrade gracefully: it throws error `-3821` ("The display stream was interrupted") and disconnects the stream entirely.

**Why it happens:**
Metal texture creation from an IOSurface (`makeTexture(descriptor:iosurface:plane:)`) creates a zero-copy alias — the IOSurface stays live until the `MTLTexture` is released. If the render pipeline holds the texture across multiple frames (e.g., caching it in a property, or scheduling GPU work without waiting), you exhaust the pool fast at 60fps.

**How to avoid:**
- Never cache the `CMSampleBuffer` or an `MTLTexture` derived from it across frame boundaries. Copy pixel data into your own Metal texture if you need persistence.
- Use triple buffering: maintain 3 owned `MTLTexture` slots and blit from the IOSurface-backed texture into the current slot each frame, then release the sample buffer immediately.
- Set `queueDepth` to 5–6 (not the max 8 — that wastes VRAM). Formula: `queueDepth - 1` must exceed the number of frames your pipeline can have in-flight simultaneously.
- Monitor for `-3821`: implement `stream(_:didStopWithError:)` in your `SCStreamDelegate` and surface this prominently in development builds.

**Warning signs:**
- Stream works for seconds then goes completely silent
- Console shows `SCStreamErrorDomain -3821`
- Problem worsens under load (more windows, higher resolution)

**Phase to address:** Capture layer foundation (Phase 1) — set up triple-buffer blit immediately, never defer this

---

### Pitfall 3: Main-Thread Permission Request Hangs App Launch

**What goes wrong:**
Calling `SCShareableContent.getWithCompletionHandler(_:)` or `SCStream.init` before the user has granted Screen Recording permission triggers a TCC (Transparency, Consent, and Control) permission dialog. If this is called synchronously on the main thread at startup, the app may appear frozen while the dialog resolves, and on macOS 15 Sequoia the dialog may appear in an unexpected order relative to your app window, confusing users.

**Why it happens:**
Developers commonly call `getWithCompletionHandler` in `applicationDidFinishLaunching` to enumerate windows immediately. The permission prompt is asynchronous but the app's UI is not ready to handle it cleanly at that point.

**How to avoid:**
- Call `SCShareableContent.getCurrentProcessShareableContent(completionHandler:)` or `requestPermission` only after the main window is visible and the user triggers a "Start capturing" action.
- Use `SCContentSharingPicker` (macOS 13+) for window selection — it embeds permission implicitly in the user's selection gesture, eliminating the separate TCC dialog entirely for the programmatic API.
- Never call any SCK API on the main thread synchronously.

**Warning signs:**
- App appears frozen for 2–30 seconds at launch on first run
- macOS 15 weekly "App wants to record your screen" prompts disrupting users

**Phase to address:** Capture layer foundation (Phase 1) — design the permission flow first, before any stream code

---

### Pitfall 4: macOS Sequoia Weekly Re-authorization Prompts

**What goes wrong:**
macOS 15 Sequoia introduced periodic Screen Recording re-authorization prompts. By default, apps are prompted weekly (and on each reboot) to confirm screen recording access continues. For a productivity tool that users run continuously, this is severely disruptive. There is no user-facing "always allow" setting.

**Why it happens:**
Apple introduced this in Sequoia as a privacy control. The "Persistent Content Capture" entitlement was meant to exempt VNC/remote desktop tools, but Apple provides no public documentation for requesting it and access is restricted.

**How to avoid:**
- Apply for the Persistent Content Capture entitlement via Apple's developer request form if the app is distributed outside the App Store as a VNC-style remote desktop tool.
- For direct distribution: communicate to users that macOS 15 will prompt monthly (Apple revised it from weekly to monthly in a Sequoia beta). Do not attempt to bypass or suppress the dialog.
- Consider whether `SCContentSharingPicker` (user-initiated picker) avoids the persistent permission requirement for your use case — it does not require a permanent TCC grant.

**Warning signs:**
- Users report random "App wants to record your screen" dialogs appearing during use
- Screen capture stops working after system reboot until user re-approves
- TestFlight beta testers complain about the app "asking for permission constantly"

**Phase to address:** Distribution/packaging phase — verify entitlement strategy before shipping

---

### Pitfall 5: Missing Info.plist Key Causes Silent Permission Denial

**What goes wrong:**
Without `NSScreenCaptureUsageDescription` in `Info.plist`, the system silently denies screen recording permission. No error is shown to the user. `SCShareableContent.getWithCompletionHandler` may return an empty content list or an error with no useful message.

**Why it happens:**
The key is not required for the app to compile or launch. It is only checked at runtime when the permission dialog would be shown. If missing, the system presents no dialog and grants no access.

**How to avoid:**
Add to `Info.plist` before any testing:
```xml
<key>NSScreenCaptureUsageDescription</key>
<string>This app captures window content to render virtual monitors in your XR glasses.</string>
```
For a sandboxed app, also include `com.apple.security.screen-capture` in the entitlements file.

**Warning signs:**
- `getWithCompletionHandler` returns successfully but `SCShareableContent.windows` is empty
- System Preferences > Privacy > Screen Recording does not show your app in the list
- No permission dialog ever appears on first run

**Phase to address:** Project setup / Phase 1 — add before first SCK call

---

### Pitfall 6: Symmetric Projection Matrices Produce Wrong Stereo Depth

**What goes wrong:**
Using a symmetric perspective projection matrix (equal left/right frustum extents) for both eyes produces images that, when viewed side-by-side through the Viture optics, either have no perceivable depth or cause eye strain. The virtual monitors appear flat or the two eye images cannot be fused correctly.

**Why it happens:**
A symmetric frustum is appropriate for a mono camera centered on the scene. Each eye in a stereo display is offset by half the IPD horizontally. The projection must be **asymmetric** (frustum shift, not camera rotation) to match. Developers confuse "offset the view matrix" (correct) with "rotate the camera" (incorrect — adds vertical parallax and breaks fusion).

**How to avoid:**
- Compute per-eye projection matrices using the Viture Luma Ultra's actual IPD (approximately 64mm — verify against hardware spec sheet) and display-to-eye distance.
- Use frustum shift (modify `left` and `right` of the frustum, keep `top`/`bottom` symmetric): `left_eye_right = standard_right - ipd/2 * near/eyeToScreen`, `left_eye_left = standard_left - ipd/2 * near/eyeToScreen`.
- Never apply IPD offset as a rotation. Apply it as a pure translation in the view matrix.
- Test with a known-depth scene: a grid of cubes at 0.5m, 1m, 2m. If the cubes appear flat or you need to squint to fuse them, the projection is wrong.

**Warning signs:**
- Virtual content appears flat despite stereo output
- Eye strain after 30 seconds of use
- Objects at different depths don't separate correctly

**Phase to address:** Stereo rendering foundation (Phase 2)

---

### Pitfall 7: Single Render Pass Without per-Eye Viewport Switching Produces Doubled Geometry

**What goes wrong:**
Rendering the scene once to the full side-by-side framebuffer without switching the viewport between draw calls for each eye fills the entire buffer with one eye's view, mirrored or clipped. The result is either the same image in both halves or a viewport that bleeds across the center.

**Why it happens:**
Metal supports `setViewports(_:)` with an array for simultaneous multi-viewport rendering, but this requires a geometry shader or `amplification` (metal mesh shaders) to index the eye. If the developer doesn't implement this, a naive single draw call ignores the viewport array.

**How to avoid:**
For this project's complexity level, use the **two-pass approach** rather than instanced multi-viewport:
1. Set viewport to left half (`[0, 0, width/2, height]`) and draw with left-eye matrices.
2. Set viewport to right half (`[width/2, 0, width/2, height]`) and draw with right-eye matrices.
Both passes share the same depth buffer. This is simpler, correct, and sufficient for a 60fps XR desktop with only a few quads.

**Warning signs:**
- Both halves of the display show identical content
- Stereo depth effect is absent (no parallax shift between halves)
- Objects in the right half are clipped on the left side

**Phase to address:** Stereo rendering foundation (Phase 2)

---

### Pitfall 8: Depth Buffer Not Cleared Between Left and Right Eye Passes

**What goes wrong:**
If the depth buffer is not explicitly cleared (or load action set to `MTLLoadActionClear`) at the start of the left-eye pass, depth values from a previous frame corrupt the current frame. If only one clear is used for the full side-by-side buffer, the right-eye pass may fail depth tests against leftover left-eye geometry, causing objects to disappear or z-fight.

**Why it happens:**
In a two-pass stereo approach, each pass is a separate `MTLRenderCommandEncoder`. Developers sometimes set `.loadAction = .load` assuming the previous clear is sufficient. But since each eye uses only half the render target width, the depth sub-region for one eye can carry stale values.

**How to avoid:**
- Set `depthAttachment.loadAction = .clear` on the very first encoder for the frame (left eye).
- Set `depthAttachment.loadAction = .load` for the second encoder (right eye), since the right half was never written by the left pass and will clear-on-first-write at the hardware level. Verify this per GPU.
- Simpler alternative: use a single render pass with two draw calls and `setViewport` between them — one depth buffer, one clear, no ambiguity.

**Warning signs:**
- Z-fighting or ghosting visible in one eye but not the other
- Objects disappear intermittently in the right eye view
- Artifacts that change when frame rate drops

**Phase to address:** Stereo rendering foundation (Phase 2)

---

### Pitfall 9: Viture SDK Coordinate System Mismatch With Metal/SceneKit Conventions

**What goes wrong:**
The Viture macOS SDK (separate from the Unity XR SDK) delivers head pose data in a coordinate system that may differ from Metal's default right-handed coordinate system. Without verifying the axis convention, applying the SDK's quaternion directly to the camera transform produces inverted or rotated motion: turning left moves the scene left instead of right, or looking up makes the scene tilt sideways.

**Why it happens:**
XR SDK vendors frequently use OpenGL convention (Y-up, Z-toward-viewer) or a device-local IMU convention that doesn't match Metal/SceneKit (also Y-up, Z-toward-viewer, right-handed). The ambiguity is in the sign of the Y-axis rotation and whether roll is clockwise or counter-clockwise when viewed from the top. The Viture Linux SDK uses raw IMU data and community implementations (EasyVXR) expose euler angles as `eulerYaw`, `eulerPitch`, `eulerRoll` without specifying which physical axis is which. The macOS SDK is separate and may differ.

**How to avoid:**
- On first integration, write a diagnostic that prints raw SDK values while physically rotating the device on each axis separately. Map each angle to physical rotation before writing any rendering code.
- Do not assume the quaternion convention matches `simd_quatf` or `SCNQuaternion`. Test with identity pose first.
- If the SDK returns Euler angles, verify the rotation order (ZYX vs XYZ vs YXZ) by rotating on one axis at a time and confirming all other angles remain zero.
- If the SDK returns a 4×4 matrix, verify whether it's row-major or column-major before passing to Metal (Metal expects column-major `float4x4`).

**Warning signs:**
- Head rotation in one axis causes unexpected rotation in another axis
- Looking straight ahead produces a non-zero pitch or roll reading
- Moving head right moves scene in wrong direction

**Phase to address:** Head tracking integration (Phase 2–3) — validate coordinate mapping before any rendering uses pose data

---

### Pitfall 10: SDK Callbacks on a Non-Main Thread Used to Update Metal State Unsafely

**What goes wrong:**
The Viture SDK delivers IMU callbacks on an internal thread (this is the pattern for all C-based SDK callbacks in XR hardware). If the callback directly mutates a `MTLBuffer` or `simd_float4x4` that the render thread reads simultaneously, you get torn reads: a partially-written matrix is used as the camera transform, causing single-frame visual artifacts that appear random.

**Why it happens:**
Swift actors and `@MainActor` don't protect against data races on plain `var` properties accessed from C callbacks. The SDK thread calls back into Swift, which does not automatically marshal to the main actor.

**How to avoid:**
- Store the latest pose in an `AtomicReference<simd_quatf>` or protect with an `os_unfair_lock` / `NSLock`.
- Better: use a triple-buffer pose ring (latest, previous, rendering). The SDK callback writes to the `latest` slot; the render loop reads from the `rendering` slot and swaps atomically at the top of each frame.
- Never call any Metal API from the SDK callback thread.

**Warning signs:**
- Single-frame visual "jumps" in head tracking that don't correlate with physical movement
- Crashes in Metal validation layer reporting "resource modified while in use"
- Symptoms only appear under high CPU load (more thread contention)

**Phase to address:** Head tracking integration (Phase 2–3)

---

### Pitfall 11: Capture→Pose→Render Latency Triangle Causes World Drift

**What goes wrong:**
The world-locked rendering pipeline has three asynchronous timestamps: (1) when the screen frame was captured, (2) when the head pose was sampled, and (3) when the rendered output reaches the display. If these are not aligned — specifically if the head pose used to compute view matrices is older than the frame being displayed — the virtual monitors appear to drift or "swim" as the user moves their head. This is the "latency triangle."

**Why it happens:**
In a naive implementation:
- SCK delivers a frame at time T₀
- The last pose was sampled at T₀ - 16ms (one frame ago)
- Rendering takes 8ms
- Output appears at T₀ + 8ms
- Total: the view matrix is 24ms stale when the frame is displayed

At 60fps each frame is 16.7ms. 24ms of latency means the virtual monitor is consistently in the wrong position by `angular_velocity × 0.024`. A 90°/sec head rotation (moderate speed) produces 2.16° of drift per frame — clearly visible as swimming.

**How to avoid:**
- Sample the head pose as **late as possible** in the render loop — after scene updates but before encoding draw calls. Never sample pose in the `captureOutput` callback and cache it.
- Use the `CMSampleBuffer.presentationTimeStamp` from SCK to know when the captured frame was valid. Sample pose at or as close to that timestamp as possible using the SDK's most recent reading.
- For v1, minimize the gap: poll pose at the start of the Metal command buffer encoding, not at the start of the frame event loop.
- For v2 (stretch goal): implement simple rotational reprojection — use the pose delta between encoding time and display time (estimated as `now + vsync_offset`) to warp the final image before presentation.

**Warning signs:**
- Virtual monitors visibly lag behind head movement
- Latency is imperceptible when stationary but obvious when moving
- Drift increases proportionally with head rotation speed

**Phase to address:** World-lock rendering (Phase 3) — establish pose sampling discipline in Phase 2 before adding reprojection

---

### Pitfall 12: CAMetalLayer Frame Pacing Stutter on Multi-Monitor Systems

**What goes wrong:**
When the Mac has more than one connected display, `CVDisplayLink` (and `CAMetalDisplayLink`) can produce inconsistent frame delivery timing, causing visible stutters even at a stable 60fps render rate. This is a known macOS bug affecting Metal rendering.

**Why it happens:**
`CVDisplayLink` is associated with a display, but when a window spans multiple displays or the system's compositor timing shifts, the display link callback timing drifts out of sync with `CAMetalLayer.nextDrawable()`. The result is frames that either block waiting for a drawable or submit too late and miss a vsync.

**How to avoid:**
- Set `maximumDrawableCount = 2` on the `CAMetalLayer` (not 3 — triple buffering increases latency for an XR app).
- Render on a dedicated high-priority thread, not the main thread. Use `Thread` with `qualityOfService = .userInteractive`.
- Target the display where the Viture glasses are connected via USB/HDMI and use a `CVDisplayLink` locked to that specific display.
- If stutters persist with multiple monitors attached: test with all other displays disconnected to confirm it's the multi-monitor stutter bug, not a pipeline issue.

**Warning signs:**
- Smooth render at 60fps on a single display becomes stuttery when a second monitor is connected
- Frame time profiling shows alternating 8ms / 25ms frame gaps (missed vsync pattern)
- Stutters disappear when mirroring is enabled

**Phase to address:** Rendering foundation (Phase 2)

---

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| Cache `CMSampleBuffer` for a frame | Simplifies texture handoff | Exhausts SCK surface pool, triggers -3821 | Never — blit immediately |
| Single projection matrix for both eyes | Gets stereo output visible quickly | No depth perception, eye strain | Never in production |
| Sample head pose once per frame at top of loop | Simple to implement | Adds full-frame latency to world-lock | MVP only, replace in Phase 3 |
| Skip `NSScreenCaptureUsageDescription` during dev | One fewer setup step | Silent permission denial on clean install | Never commit without it |
| Hold `SCStreamOutput` as a local variable | Quick prototype | Stream silently never delivers frames | Never — caught in Phase 1 |
| Symmetric projection matrices | Easier math | Wrong stereo depth | Never |
| Use Euler angles directly from SDK without axis verification | Fast to write | Inverted or swapped axes in rendering | Never ship without axis diagnostic |

---

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| ScreenCaptureKit | Calling `getWithCompletionHandler` at app launch | Defer until user action; show permission UI only when user initiates capture |
| ScreenCaptureKit | Using `.load` instead of `.clear` for the first render pass in a frame | Always `.clear` the depth attachment at the top of each frame |
| SCStream + Metal | Holding `MTLTexture` derived from IOSurface between frames | Blit to an owned texture immediately, release the sample buffer before returning from `captureOutput` |
| Viture SDK | Passing SDK quaternion directly to Metal transforms | Verify axis convention empirically with per-axis rotation test before any rendering integration |
| Viture SDK | Updating Metal buffers from SDK callback thread | Use lock or atomic ring buffer; never touch Metal from a C callback thread |
| macOS entitlements | Notarizing without `NSScreenCaptureUsageDescription` | Add the key with a user-facing description before any test distribution |
| macOS Sequoia | Assuming screen recording permission is permanent | Design permission-request UX for periodic re-prompts; do not cache permission state across app launches |

---

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| Not blitting IOSurface to owned texture before render | -3821 stream disconnection under GPU load | Triple-buffer blit in `captureOutput` | At GPU load threshold, immediately |
| Two separate render passes with separate depth buffers per eye | Depth artifacts in one eye | One shared depth buffer, two viewports | Always subtle, obvious under complex scenes |
| Pose sampled once at top of frame loop | World drift proportional to head speed | Sample pose as late as possible in encoder setup | Obvious during fast head movement |
| `queueDepth = 3` (default) with slow processing | Dropped frames at 60fps | Set `queueDepth = 5` and blit immediately | At 60fps when processing takes >8ms |
| `maximumDrawableCount = 3` on `CAMetalLayer` | +16ms display latency added to XR pipeline | Use `maximumDrawableCount = 2` | Always adds latency; unacceptable for XR |

---

## Security Mistakes

| Mistake | Risk | Prevention |
|---------|------|------------|
| Storing captured window content to disk without user consent | Privacy violation, App Store rejection | Never persist captured frames; process in-memory only |
| Requesting "all windows" SCK filter when only specific windows needed | Unnecessarily broad screen access | Use `SCContentFilter` with explicit window list; request minimum scope |
| Shipping without `NSScreenCaptureUsageDescription` | Silent failure on clean install, App Review rejection | Add key before any distribution |

---

## UX Pitfalls

| Pitfall | User Impact | Better Approach |
|---------|-------------|-----------------|
| Triggering permission dialog at app launch before any UI shows | Confusing — no context for why permission is needed | Show onboarding screen first explaining what the app does |
| No indication when SCK stream drops (-3821) | App appears frozen, user doesn't know to restart | Monitor stream delegate, show "Stream interrupted — click to reconnect" |
| Static screen content not updating the texture | Virtual monitor appears frozen mid-session | SCK does not send frames for static content; detect this by comparing frame timestamps and show a subtle "live" indicator |
| World-locked monitors drifting without explanation | Disorienting; users blame the hardware | Show a "recenter" button to reset world-lock origin on demand |

---

## "Looks Done But Isn't" Checklist

- [ ] **Screen capture permissions:** The app works in dev (dev identity has silent approval) but will fail on a new Mac without `NSScreenCaptureUsageDescription` — verify on a clean account
- [ ] **IOSurface release:** Capture appears to work in testing but will drop frames under sustained GPU load if sample buffers are not released promptly — run with Metal validation and check for -3821 after 60 seconds
- [ ] **Stereo depth:** Side-by-side output renders in both eyes but with symmetric projection — verify depth by placing a virtual quad at 0.5m and confirming binocular parallax is visible
- [ ] **Head tracking axes:** SDK integration compiles and runs but axis mapping was never verified — rotate on each axis individually and confirm only one Euler angle changes
- [ ] **Multi-display timing:** Frame pacing looks correct on dev machine with one display but stutters with two — test with external display connected before shipping
- [ ] **Sequoia permissions:** Works on dev machine (permanent grant) but weekly re-auth dialog will appear for users — test on a VM or secondary account with clean permission state

---

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| SCStream output deallocated | LOW | Refactor `CaptureManager` to self-conform to `SCStreamOutput`; test immediately |
| -3821 surface pool exhaustion | MEDIUM | Add triple-buffer blit architecture; requires rethinking the capture→render handoff path |
| Wrong projection matrices | LOW | Replace with asymmetric frustum computation; no architectural change |
| Axis convention mismatch (coordinate system) | LOW–MEDIUM | Add axis-diagnostic mode, remap in transform layer; no rewrite |
| Latency triangle drift | MEDIUM | Move pose sampling later in pipeline; may require restructuring the frame loop |
| Sequoia permission prompts breaking UX | HIGH if no entitlement | Apply for Persistent Content Capture entitlement; redesign permission UX as fallback; cannot be fixed in code alone |

---

## Pitfall-to-Phase Mapping

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| SCStream output object collected | Phase 1 (Capture layer) | `captureOutput` called within 1 second of stream start |
| IOSurface pool exhaustion (-3821) | Phase 1 (Capture layer) | Run at 60fps for 5 minutes under GPU load; no -3821 errors |
| Permission request blocking main thread | Phase 1 (Capture layer) | Permission prompt appears only after user action, not at launch |
| Sequoia weekly re-auth disruption | Pre-distribution / Phase 4 | Test on clean account; entitlement request submitted |
| Missing `NSScreenCaptureUsageDescription` | Phase 1 setup | Clean install on a separate account works on first run |
| Symmetric projection / wrong stereo depth | Phase 2 (Stereo rendering) | Binocular parallax visible on near/far objects; no eye strain after 2 minutes |
| Single viewport for both eyes | Phase 2 (Stereo rendering) | Left and right halves show different perspectives |
| Depth buffer not cleared | Phase 2 (Stereo rendering) | No z-fighting visible in either eye |
| Viture coordinate system mismatch | Phase 2–3 (Tracking integration) | Axis diagnostic: one angle changes per physical rotation axis |
| SDK callbacks mutating Metal state | Phase 2–3 (Tracking integration) | Metal validation enabled; no "resource modified while in use" errors |
| Latency triangle drift | Phase 3 (World-lock) | World-locked monitors stable at up to 180°/sec head rotation |
| CAMetalLayer multi-display stutter | Phase 2 (Rendering foundation) | Stable frame times with secondary display connected |

---

## Sources

- Apple WWDC22 "Take ScreenCaptureKit to the next level" (frame queue, IOSurface, MinimumFrameInterval): https://developer.apple.com/videos/play/wwdc2022/10155/
- Apple Developer Forums — SCStream weak output reference issue (frame dropping silently): https://developer.apple.com/forums/thread/733077
- fatbobman.com ScreenSage architecture post (SCK -3821 silent disconnection, static frame bug): https://fatbobman.com/en/posts/screensage-from-pixel-to-meta/
- nonstrict.eu "A look at ScreenCaptureKit on macOS Sonoma" (SCContentSharingPicker gotchas): https://nonstrict.eu/blog/2023/a-look-at-screencapturekit-on-macos-sonoma/
- Michael Tsai blog — Sequoia Screen Recording Prompts and Persistent Content Capture Entitlement: https://mjtsai.com/blog/2024/08/08/sequoia-screen-recording-prompts-and-the-persistent-content-capture-entitlement/
- Apple Developer Forums — entitlement for screen capture: https://developer.apple.com/forums/thread/683860
- Apple Developer Documentation — `queueDepth`: https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/queuedepth
- Apple Developer Documentation — `setViewports(_:)`: https://developer.apple.com/documentation/metal/mtlrendercommandencoder/2869738-setviewports
- Apple Developer Documentation — `displaySyncEnabled` / `CAMetalDisplayLink`: https://developer.apple.com/documentation/quartzcore/cametallayer/displaysyncenabled
- Apple Developer Forums — multiple display frame stutters: https://developer.apple.com/forums/thread/112468
- XREAL SDK — Display Stability / Reprojection: https://docs.xreal.com/Rendering/Warping
- ACM SIGGRAPH "Perceptual Requirements for World-Locked Rendering in AR and VR": https://dl.acm.org/doi/fullHtml/10.1145/3610548.3618134
- Oculus Rift asymmetric frustum reference: http://rifty-business.blogspot.com/2013/10/understanding-matrix-transformations.html
- EasyVXR (community Viture SDK wrapper, IMU struct reference): https://github.com/Wojtekb30/EasyVXR
- codegenes.net — Metal triple-buffer synchronization for camera capture: https://www.codegenes.net/blog/screen-tearing-and-camera-capture-with-metal/

---
*Pitfalls research for: macOS XR virtual desktop — ScreenCaptureKit + Metal + Viture Luma Ultra*
*Researched: 2026-04-14*
