# Feature Research

**Domain:** macOS XR virtual desktop (Viture Luma Ultra)
**Researched:** 2026-04-14
**Confidence:** MEDIUM — table stakes derived from Breezy Desktop source + Immersed/Virtual Desktop feature analysis; some Viture macOS SDK specifics are LOW confidence pending direct SDK access

---

## Feature Landscape

### Table Stakes (Users Expect These)

Features users assume exist. Missing these = product feels incomplete.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Live window/screen capture | The whole product is "see your Mac in XR" — no capture = nothing to show | MEDIUM | ScreenCaptureKit SCStream; per-window or full display; requires screen recording permission from user |
| Correct stereo output | Glasses show two panels (one per eye) — mono output looks broken immediately | HIGH | Side-by-side stereo to fill Viture display; must respect device FOV and optical geometry; Single-pass Metal render |
| World-locked monitors (rotation only) | If the screen chases your head, it's useless as a desktop replacement | MEDIUM | IMU data from Viture macOS SDK drives inverse-rotation transform on quad; yaw/pitch/roll applied to cancel head motion |
| Stable, low-drift tracking | A floating screen that slowly slides or jitters is unusable within minutes | HIGH | Gyro drift is an inherent IMU problem; must apply complementary/Kalman filtering on raw IMU data or rely on SDK-level fusion; key quality gate |
| Re-centering gesture or hotkey | User looks away, screen drifts over time, needs manual reset | LOW | Keyboard shortcut or on-glasses tap (Breezy uses 2-tap) to snap screen to current head orientation |
| Reasonable default monitor placement | Screen should appear in front of the user at a comfortable distance on launch | LOW | Fixed initial placement (e.g., 1.5m ahead, horizontal center, slight downward pitch); no UI needed for v1 |
| Two visible monitor quads | PROJECT.md specifies 2 monitors as the core value — one is just mirroring | MEDIUM | Two distinct ScreenCaptureKit SCStream captures → two Metal textured quads; side-by-side or offset layout |
| Screen Recording permission flow | macOS requires explicit user permission; if skipped or denied, nothing works | LOW | Standard Privacy & Security flow; must present clear prompt and handle denial state gracefully |
| Readable text quality | If text is blurry, the app fails its core use case for knowledge workers | MEDIUM | High-res texture (at least 1080p per quad); ScreenCaptureKit can capture at Retina resolution; Metal bilinear or trilinear filtering |

### Differentiators (Competitive Advantage)

Features that set the product apart. Not required, but valuable.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Per-window capture (not full-screen mirroring) | Capture specific apps, not the whole desktop — privacy, flexibility, works over multiple Spaces | MEDIUM | SCWindowFilter vs SCDisplayFilter; allows showing Xcode on one quad, browser on another |
| Smooth follow / auto-recenter after large drift | Screen "catches up" gently when user looks far away — Breezy calls this "Smooth Follow" | MEDIUM | Lerp/slerp toward center-of-vision when angular offset exceeds threshold (e.g., 45°); avoids jarring snap |
| Persistent monitor positions across sessions | User sets up their workspace once; relaunching restores it | LOW | Serialize quad transforms (position, size, angle) to UserDefaults or plist |
| Multi-Space / per-app assignment | One quad = Xcode, one quad = browser, changes dynamically | HIGH | Requires SCRunningApplication filters and stream hot-swap; complex, v2+ |
| Configurable monitor size and distance | Different users want screens closer/larger or further/smaller | MEDIUM | Scale and depth (Z) exposed as sliders or keyboard shortcuts; good UX differentiator |
| Native macOS menu bar app | No dock icon, no full app window — lives as a status bar item | LOW | NSStatusItem; expected for a utility that runs alongside other apps |
| Frame rate / quality tradeoff control | Power users on battery want 30fps low-CPU; deskbound users want 60fps | LOW | Expose SCStreamConfiguration.minimumFrameInterval as a setting |

### Anti-Features (Commonly Requested, Often Problematic)

Features that seem good but create problems.

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|-----------------|-------------|
| Click-through / spatial cursor interaction | Users want to click on virtual monitors without touching keyboard | Requires raycasting from head pose + synthetic mouse event injection — entirely separate input system; major scope expansion; PROJECT.md explicitly defers this | Keep standard keyboard/trackpad input; cursor interaction is v2+ |
| Full 6DOF positional tracking in v1 | "More immersive" — monitors shift as user physically moves | Viture Luma Ultra may expose 6DOF through the neckband SDK, but architecture must be validated before building on it; adds positional math on top of rotational math; complexity doubles | Architecture must be protocol-backed so 6DOF can be dropped in later; DO NOT implement in v1 |
| Spatial audio / speaker placement | Ambient audio from positioned monitors | Unrelated to core productivity value; AVFoundation audio routing from ScreenCaptureKit adds separate complexity layer; distraction from visual fidelity | Defer entirely; SCStream can capture audio but routing to virtual positions is v3+ |
| Full configuration UI (settings panel) | Users want a dedicated preferences window | For v1, hardcoded defaults are sufficient; building a full SwiftUI preferences window is a distraction from the rendering pipeline | Use NSUserDefaults with sensible defaults; expose at most two keyboard shortcuts for recenter and quit |
| Multi-user / collaborative workspaces | Share your virtual desk with others (Immersed's main differentiator) | Requires networking, identity, server infrastructure — months of work orthogonal to the core rendering prototype | Not applicable to this product category; solo productivity tool |
| Virtual environments / backgrounds | Replace the real world with a virtual office or nature scene | Viture Luma Ultra is a see-through AR device, not VR — the "background" IS the real world; environment replacement would require opaque mode and different rendering | Embrace the see-through nature; real world is the background by design |
| Window management automation (auto-layout) | Automatically arrange apps into the XR space | Requires Accessibility API + window management logic well beyond rendering scope | Manual positioning via keyboard shortcuts is sufficient for v1 |
| Built-in app streaming / casting from phone | Some users want to cast iPhone screen | Separate connectivity stack (Bonjour, USB, AirPlay) on top of everything else | macOS window capture already covers the primary use case |

---

## Feature Dependencies

```
[Stereo Output]
    └──requires──> [Metal render pipeline with SBS output]
                       └──requires──> [Correct Viture display geometry params]

[World-Locked Monitors]
    └──requires──> [Live IMU data from Viture macOS SDK]
                       └──requires──> [SDK integration + low-latency polling]
    └──requires──> [Metal quad transform updated per-frame]

[Two Monitor Quads]
    └──requires──> [Two independent ScreenCaptureKit SCStream instances]
    └──requires──> [Metal scene with two textured quads]

[Re-centering]
    └──requires──> [World-Locked Monitors] (needs a reference pose to snap to)

[Smooth Follow / Auto-Recenter]
    └──requires──> [Re-centering] (generalizes the snap into a lerp)
    └──enhances──> [World-Locked Monitors]

[Per-Window Capture]
    └──requires──> [ScreenCaptureKit live capture] (uses SCWindowFilter variant)
    └──enhances──> [Two Monitor Quads]

[6DOF Positional Tracking]
    └──requires──> [Rotational tracking] (3DOF is a subset)
    └──requires──> [Validated Viture positional SDK]
    ──conflicts──> [v1 scope]
```

### Dependency Notes

- **World-Locked Monitors requires Live IMU data:** The entire spatial stability promise depends on the Viture macOS SDK delivering orientation at sufficient rate (ideally 60-120Hz) with acceptable drift. This is the highest-risk dependency in v1.
- **Two Monitor Quads requires two SCStream instances:** ScreenCaptureKit supports concurrent streams; each stream is independent and can capture a different window or display. CPU/GPU cost doubles.
- **Stereo output requires Viture display geometry:** IPD, lens FOV, and whether the Luma Ultra requires barrel-distortion correction must be confirmed against the SDK docs. Without this, stereo will be off. Confidence: LOW — needs direct SDK investigation.
- **Smooth Follow conflicts with v1 scope:** Useful but requires a stable baseline first. Implement only after world-lock is stable.

---

## MVP Definition

### Launch With (v1)

Minimum viable product — what's needed to validate the concept.

- [ ] Live capture of 1-2 macOS windows via ScreenCaptureKit — without this, there is nothing to display
- [ ] Two Metal-rendered textured quads in stereo side-by-side — the spatial display surface
- [ ] Viture macOS SDK integration delivering 3DOF orientation per-frame — drives world-lock
- [ ] World-locked monitor transform (rotation inverse applied to quads) — the core value proposition
- [ ] Re-centering keyboard shortcut (e.g., Cmd+R) — escape hatch when drift accumulates
- [ ] Screen Recording permission prompt and graceful denial handling — required by macOS privacy model
- [ ] Sensible default placement: two quads centered in front, ~1.5m distance, ~45° separation — first-run experience

### Add After Validation (v1.x)

Features to add once core world-lock is confirmed stable.

- [ ] Configurable monitor size and distance — once layout is validated, users will want to adjust
- [ ] Persistent monitor positions across sessions — quality-of-life once core loop is proven
- [ ] Smooth follow / auto-recenter on large drift — improves comfort during longer sessions
- [ ] Native menu bar app (NSStatusItem, no dock icon) — polish for daily-driver use
- [ ] Per-window capture with stream hot-swap — enables true dual-app layout, not just dual-display mirror

### Future Consideration (v2+)

Features to defer until product-market fit is established.

- [ ] Click-through spatial cursor — requires input system redesign; PROJECT.md explicit deferral
- [ ] 6DOF positional tracking — architecture is prepared (protocol-backed layers); needs validated Viture SDK support
- [ ] Frame rate / quality control UI — only relevant once base performance is understood
- [ ] Multi-Space / per-app assignment with dynamic stream switching — high complexity, low v1 value

---

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---------|------------|---------------------|----------|
| Live ScreenCaptureKit capture | HIGH | MEDIUM | P1 |
| Stereo Metal render pipeline | HIGH | HIGH | P1 |
| Viture SDK 3DOF integration | HIGH | MEDIUM | P1 |
| World-locked quad transform | HIGH | MEDIUM | P1 |
| Re-centering hotkey | HIGH | LOW | P1 |
| Default monitor placement | MEDIUM | LOW | P1 |
| Screen Recording permission flow | HIGH | LOW | P1 |
| Readable text quality (high-res texture) | HIGH | MEDIUM | P1 |
| Configurable size/distance | MEDIUM | MEDIUM | P2 |
| Persistent positions across sessions | MEDIUM | LOW | P2 |
| Smooth follow / auto-recenter | MEDIUM | MEDIUM | P2 |
| Menu bar app (no dock icon) | MEDIUM | LOW | P2 |
| Per-window capture | HIGH | MEDIUM | P2 |
| Spatial cursor / click-through | HIGH | HIGH | P3 |
| 6DOF positional tracking | HIGH | HIGH | P3 |
| Frame rate / quality control UI | LOW | LOW | P3 |
| Multi-Space dynamic assignment | MEDIUM | HIGH | P3 |

**Priority key:**
- P1: Must have for launch
- P2: Should have, add when possible
- P3: Nice to have, future consideration

---

## Competitor Feature Analysis

| Feature | Breezy Desktop (Linux) | Immersed (macOS/VR) | Virtual Desktop (VR) | Our Approach |
|---------|------------------------|---------------------|----------------------|--------------|
| Display mode | World-locked (default) + follow mode | World-locked, moveable | World-locked + head-lock | World-locked only, v1 |
| Re-centering | 2-tap on glasses + keyboard shortcut | On-controller button / auto | Keyboard shortcut | Keyboard shortcut (Cmd+R) |
| Auto-recenter on drift | Yes (Automatic Recentering, Pro tier) | Yes | Yes | v1.x (post-validation) |
| Number of monitors | Up to display system limit | Up to 5 (Pro) | Typically 1-3 | 2, hardcoded v1 |
| Per-window capture | Display-level (X11/Wayland virtual display) | Virtual display creation | Mirror only | Per-window via SCWindowFilter |
| Platform native stack | Linux X11/Wayland + Vulkan | Cross-platform streamer | Cross-platform streamer | macOS-native: Swift + Metal |
| 6DOF support | Pro tier | Yes | Yes | Architecture-ready, v2 |
| Spatial cursor | No (VR-lite joystick mode only) | Yes (full hand/controller) | Yes (full controller) | Explicitly deferred to v2 |
| Configuration UI | Breezy Desktop app + env vars | Full preferences panel | Full preferences panel | Minimal: defaults + 2 shortcuts |
| Audio capture | Not primary feature | Yes | Yes | Not v1 |

---

## Key Risk: IMU Data Quality

The entire product value chain collapses if the Viture macOS SDK does not deliver sufficiently stable, low-latency 3DOF orientation data. Breezy Desktop documents significant effort around gyro drift correction and re-centering as compensating mechanisms. The quality of the world-lock effect is entirely dependent on:

1. SDK polling rate (ideally ≥60Hz at the app level)
2. SDK-internal sensor fusion quality (is drift correction done in firmware or must the app do it?)
3. Whether the Luma Ultra's on-device tracking chip applies any stabilization before data reaches the macOS SDK

This should be validated in Phase 1 before building the full render pipeline on top of it. If raw IMU data has unacceptable drift (>2° per minute), a re-centering workflow becomes critical infrastructure rather than a convenience feature.

Confidence: LOW — no direct macOS SDK documentation was accessible during this research. The Viture developer page confirms macOS SDK existence but specific API surface and data quality are unverified.

---

## Sources

- Breezy Desktop README: https://github.com/wheaney/breezy-desktop (feature set, re-centering behavior, display modes, Smooth Follow description)
- Immersed feature overview: https://immersed.com/faq + https://zybervr.com/blogs/news/immersed-vs-virtual-desktop-the-ultimate-guide-to-vr-productivity-tools
- Virtual Desktop head-lock behavior: Steam community discussions and release notes
- Viture developer page (SDK platform confirmation): https://www.viture.com/developer
- ScreenCaptureKit documentation: https://developer.apple.com/documentation/screencapturekit/
- Spatial content placement (30° ergonomic rule): IxDF Spatial UI Design guidance
- XR glasses drift and sensor fusion: https://inairspace.com/blogs/learn-with-inair/vr-screen-keeps-moving-a-deep-dive-into-the-causes-and-solutions-for-unwanted-drift

---
*Feature research for: macOS XR virtual desktop (Viture Luma Ultra)*
*Researched: 2026-04-14*
