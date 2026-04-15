# Roadmap: macOS XR Desktop (Viture Luma Ultra)

## Overview

Four phases, each delivering one independently verifiable capability. Capture comes first because pool exhaustion and delegate deallocation bugs must be contained before the render layer builds on top of them. Stereo rendering is validated against static test textures before tracking is added — mixing those two concerns makes bugs indistinguishable. Tracking is validated after the render pipeline is trusted. Integration wires all three layers together and confirms the full end-to-end loop: two live windows, world-locked, in stereo, at 60fps.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [ ] **Phase 1: Capture Foundation** - CaptureManager delivers live MTLTexture frames from real windows via SCStream with zero-copy IOSurface, stable at 60fps for 10+ minutes
- [ ] **Phase 2: Stereo Render Pipeline** - RenderEngine renders two textured quads in correct side-by-side stereo at 60fps on the Viture 3840x1080 display, with asymmetric frustum projection
- [ ] **Phase 3: Head Tracking and World-Lock** - VitureTracker delivers verified HeadPose data and virtual monitors remain fixed in world space as the user moves their head
- [ ] **Phase 4: Integration and End-to-End** - AppCoordinator wires all layers; two live windows displayed as world-locked stereo monitors, validated at 60fps for 10 minutes

## Phase Details

### Phase 1: Capture Foundation
**Goal**: CaptureManager reliably delivers live MTLTexture frames from real macOS windows at 60fps with no IOSurface pool exhaustion
**Depends on**: Nothing (first phase)
**Requirements**: SCK-01, SCK-02, SCK-03, SCK-04, ARC-03
**Success Criteria** (what must be TRUE):
  1. App requests Screen Recording permission on first launch and handles denied/revoked state — no crash, clear recovery message shown to user
  2. User can select which macOS window appears on each of the two virtual monitor slots
  3. Live window frames arrive at 60fps for 10+ minutes with no -3821 stream disconnection errors
  4. Capture correctly handles static-content frames — no tearing or freezing when window content has not changed
  5. TexturePool hands off MTLTexture to render-side consumer with correct IOSurface blit discipline (blit-and-release within captureOutput, no sample buffer held across frames)
**Plans**: 5 plans
Plans:
- [x] 01-01-PLAN.md — Xcode project scaffold (AppKit lifecycle, macOS 13, frameworks linked, NSScreenCaptureUsageDescription)
- [x] 01-02-PLAN.md — PermissionGateway (TCC probe, async request, denied-state NSAlert recovery)
- [ ] 01-03-PLAN.md — TexturePool + CaptureManager (triple-buffer, blit-and-release, CVMetalTextureCache, -3821 monitoring)
- [ ] 01-04-PLAN.md — WindowPicker (SCShareableContent enumeration, SCContentFilter factory)
- [ ] 01-05-PLAN.md — AppCoordinator wiring + 10-minute pipeline verification checkpoint

### Phase 2: Stereo Render Pipeline
**Goal**: RenderEngine renders two floating monitor quads in correct side-by-side stereo at 60fps on the Viture Luma Ultra display
**Depends on**: Phase 1
**Requirements**: RND-01, RND-02, RND-03, RND-04
**Success Criteria** (what must be TRUE):
  1. Two textured quads appear as floating monitors in the Viture display at a readable distance
  2. Stereo output is correct side-by-side at 3840x1080 — each eye receives its own viewport with correct IPD offset
  3. Asymmetric frustum projection is used per eye — flat stereo artifact is absent
  4. Both eyes rendered in a single draw call per quad via Metal viewport array (`[[viewport_array_index]]`)
**Plans**: TBD
**UI hint**: yes

### Phase 3: Head Tracking and World-Lock
**Goal**: VitureTracker delivers verified head orientation data and virtual monitors remain fixed in world space as the user rotates their head
**Depends on**: Phase 2
**Requirements**: TRK-01, TRK-02, TRK-03, TRK-04
**Success Criteria** (what must be TRUE):
  1. Viture macOS SDK integrated and delivering head orientation (yaw/pitch/roll or quaternion) at >= 60Hz — axis conventions verified empirically against hardware
  2. Virtual monitors remain visually fixed in world space as the user rotates their head — no swimming or drift visible during normal use
  3. User can re-center monitors to current gaze direction via a keyboard shortcut (e.g., Cmd+R)
  4. HeadPose struct carries `position: SIMD3<Float>` field (populated with `.zero` for v1) — 6DOF can be dropped in without changing any rendering code
**Plans**: TBD

> **Risk flag (Phase 3):** Viture macOS SDK may require macOS Sequoia 15+. Confirm deployment target before starting this phase. Also verify SDK coordinate axis conventions empirically with hardware before writing any view matrix code — axis mismatch produces inverted motion and is not diagnosable from docs alone.

### Phase 4: Integration and End-to-End
**Goal**: AppCoordinator wires CaptureManager, RenderEngine, and TrackingProvider into a working app — two live windows displayed as world-locked stereo monitors
**Depends on**: Phase 3
**Requirements**: ARC-01, ARC-02
**Success Criteria** (what must be TRUE):
  1. Two live macOS windows are visible as world-locked stereo monitor quads in the Viture display simultaneously
  2. App runs at 60fps for 10 minutes with no -3821 errors, no visible drift accumulation beyond 1 degree/minute, and text on the captured windows is readable
  3. CaptureManager, RenderEngine, and TrackingProvider are implemented as protocol-backed modules — each independently testable with no cross-layer type leakage
**Plans**: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Capture Foundation | 2/5 | In Progress|  |
| 2. Stereo Render Pipeline | 0/? | Not started | - |
| 3. Head Tracking and World-Lock | 0/? | Not started | - |
| 4. Integration and End-to-End | 0/? | Not started | - |
