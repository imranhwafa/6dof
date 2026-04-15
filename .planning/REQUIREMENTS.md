# Requirements: macOS XR Desktop (Viture Luma Ultra)

**Defined:** 2026-04-14
**Core Value:** Two live macOS windows rendered as stable 3D quads in the Viture display — head moves, monitors stay fixed in space.

## v1 Requirements

### Capture

- [x] **SCK-01**: App requests Screen Recording permission on first launch and handles denied/revoked state gracefully
- [ ] **SCK-02**: User can select which macOS window to display on each of the two virtual monitors
- [x] **SCK-03**: App captures live window frames via SCStream using IOSurface zero-copy path (no CPU memcpy)
- [x] **SCK-04**: Capture layer handles static-content frames gracefully (SCK optimization — no tearing or freezing when window hasn't changed)

### Rendering

- [ ] **RND-01**: App renders two floating monitor quads in 3D using Metal
- [ ] **RND-02**: Stereo output correctly targets Viture Luma Ultra display (3840×1080 side-by-side, two eyes)
- [ ] **RND-03**: Asymmetric frustum projection used per eye (not symmetric — prevents flat stereo)
- [ ] **RND-04**: Single-pass stereo rendered via Metal viewport array (one draw call per quad, two eyes via `[[viewport_array_index]]`)

### Tracking

- [ ] **TRK-01**: Viture macOS SDK integrated as C binary with Swift bridging header (arm64, manual Xcode link)
- [ ] **TRK-02**: Head orientation (yaw/pitch/roll or quaternion) polled from Viture Carina SDK each frame
- [ ] **TRK-03**: Virtual monitors remain fixed in world space as head rotates (world-locked rendering)
- [ ] **TRK-04**: User can re-center monitors to current gaze direction via a keyboard hotkey

### Architecture

- [ ] **ARC-01**: CaptureManager, RenderEngine, and TrackingProvider implemented as protocol-backed, independently-testable modules
- [ ] **ARC-02**: `HeadPose` struct includes `position: SIMD3<Float>` (zero vector for v1) so 6DOF positional tracking can be dropped in without refactoring
- [x] **ARC-03**: `TexturePool` handles SCStream → Metal texture hand-off with correct IOSurface blit discipline (blit immediately, release sample buffer before returning from `captureOutput`)

## v2 Requirements

### Interaction

- **INT-01**: Click-through raycasting — clicks on virtual monitor surface hit the real underlying macOS window
- **INT-02**: Spatial cursor rendered in 3D space aligned with mouse position on virtual quad

### Tracking

- **TRK-05**: Full 6DOF positional tracking via Viture macOS SDK (swap `VitureTracker` for `SixDOFTracker` — no render changes)
- **TRK-06**: Smooth Follow mode — monitors lazily drift toward gaze center (Breezy-style lerp)
- **TRK-07**: Automatic re-centering when gaze exits monitor boundary

### Polish

- **POL-01**: Window picker UI uses SCContentSharingPicker (macOS 14+) for better UX
- **POL-02**: Persistent monitor layout (position, size, window assignments saved across launches)
- **POL-03**: Menu bar app with show/hide toggle and settings panel
- **POL-04**: Notarized distribution build with Persistent Content Capture entitlement

## Out of Scope

| Feature | Reason |
|---------|--------|
| Linux code / Breezy Desktop port | macOS-native from scratch — no X11, no Wayland, no Linux APIs |
| Unity / game engine | Native macOS app; Unity SDK not applicable |
| RealityKit / SceneKit | Cannot control stereo pipeline; use Metal directly |
| OpenGL | Deprecated since macOS 10.14 |
| Multi-monitor configuration UI | v2 — hardcode layout for v1 |
| Barrel distortion correction | Verify hardware handles it; defer software correction unless artifacts observed |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| SCK-01 | Phase 1 — Capture Foundation | Complete |
| SCK-02 | Phase 1 — Capture Foundation | Pending |
| SCK-03 | Phase 1 — Capture Foundation | Complete |
| SCK-04 | Phase 1 — Capture Foundation | Complete |
| ARC-03 | Phase 1 — Capture Foundation | Complete |
| RND-01 | Phase 2 — Stereo Render Pipeline | Pending |
| RND-02 | Phase 2 — Stereo Render Pipeline | Pending |
| RND-03 | Phase 2 — Stereo Render Pipeline | Pending |
| RND-04 | Phase 2 — Stereo Render Pipeline | Pending |
| TRK-01 | Phase 3 — Head Tracking and World-Lock | Pending |
| TRK-02 | Phase 3 — Head Tracking and World-Lock | Pending |
| TRK-03 | Phase 3 — Head Tracking and World-Lock | Pending |
| TRK-04 | Phase 3 — Head Tracking and World-Lock | Pending |
| ARC-01 | Phase 4 — Integration and End-to-End | Pending |
| ARC-02 | Phase 4 — Integration and End-to-End | Pending |

**Coverage:**
- v1 requirements: 15 total
- Mapped to phases: 15
- Unmapped: 0 ✓

---
*Requirements defined: 2026-04-14*
*Last updated: 2026-04-14 after roadmap creation*
