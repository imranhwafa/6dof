---
phase: 01-capture-foundation
plan: 05
subsystem: capture
tags: [ScreenCaptureKit, AppCoordinator, AppDelegate, SCStream, MTLTexture, IOSurface]

# Dependency graph
requires:
  - phase: 01-capture-foundation plan 01
    provides: Xcode project scaffold, AppKit lifecycle, linked frameworks
  - phase: 01-capture-foundation plan 02
    provides: PermissionGateway (TCC probe, async request, denied NSAlert)
  - phase: 01-capture-foundation plan 03
    provides: TexturePool (triple-buffer) + CaptureManager (zero-copy blit, -3821 monitoring)
  - phase: 01-capture-foundation plan 04
    provides: WindowPicker (SCShareableContent enumeration, SCContentFilter factory)
provides:
  - AppCoordinator orchestrating permission → enumeration → capture start → frame logging
  - Complete Phase 1 end-to-end capture pipeline verified at 60fps for 10+ minutes
  - Static-content gap handling confirmed (no crash, no nil-texture error)
  - AppDelegate updated to own coordinator and defer start() after makeKeyAndOrderFront
affects: [02-stereo-render, 04-integration]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - AppCoordinator as @MainActor orchestrator owned by AppDelegate
    - permission → enumerate → capture pipeline sequence with async/await
    - Coordinator.start() deferred to after makeKeyAndOrderFront to satisfy TCC constraints

key-files:
  created:
    - SixDOF/App/AppCoordinator.swift
  modified:
    - SixDOF/AppDelegate.swift

key-decisions:
  - "AppCoordinator is @MainActor final class — all pipeline orchestration on main actor to match AppDelegate lifecycle"
  - "Phase 1 auto-selects first two enumerated windows for capture — Phase 4 will add UI picker (SCK-02 full UX)"
  - "coord.start() called after makeKeyAndOrderFront in AppDelegate — satisfies TCC deferred permission pattern"

patterns-established:
  - "Coordinator pattern: AppDelegate owns coordinator, calls start() after window visible, coordinator owns all subsystems"
  - "Pipeline sequencing: permission gate → enumerate → log → capture start, each step guarded with early return on failure"

requirements-completed: [SCK-01, SCK-02, SCK-03, SCK-04, ARC-03]

# Metrics
duration: ~20min
completed: 2026-04-15
---

# Phase 01, Plan 05: AppCoordinator Wiring + Pipeline Verification Summary

**AppCoordinator wires PermissionGateway, WindowPicker, and CaptureManager into a verified end-to-end capture pipeline delivering live MTLTexture frames at 60fps for 10+ minutes with no -3821 errors**

## Performance

- **Duration:** ~20 min
- **Started:** 2026-04-15T04:20:00Z
- **Completed:** 2026-04-15T04:37:32Z
- **Tasks:** 2 (1 auto + 1 checkpoint:human-verify)
- **Files modified:** 2

## Accomplishments

- AppCoordinator created as @MainActor orchestrator owning PermissionGateway, WindowPicker, and CaptureManager
- AppDelegate updated: removed old PermissionGateway wiring, now owns AppCoordinator and calls start() after makeKeyAndOrderFront
- Human verification confirmed: permission dialog after window visible, window list enumerated to console, frame logs at ~60fps for both slots
- 10-minute run completed with no -3821 stream disconnection errors
- Static-content gap handling confirmed — frame log pauses when window idle, resumes on update, no crash or nil-texture error

## Task Commits

1. **Task 1: Implement AppCoordinator — permission gate → window enumeration → capture start → frame logging** - `0d584f9` (feat)
2. **Task 2: Human verification checkpoint** — APPROVED (all 5 criteria passed)

## Files Created/Modified

- `SixDOF/App/AppCoordinator.swift` - @MainActor coordinator orchestrating permission → enumeration → capture start → frame logging
- `SixDOF/AppDelegate.swift` - Updated to own AppCoordinator, calls coord.start() after makeKeyAndOrderFront

## Decisions Made

- AppCoordinator is `@MainActor final class` — pipeline orchestration on main actor matches AppDelegate lifecycle and avoids data race on coordinator reference
- Phase 1 auto-selects first two enumerated windows (no picker UI yet) — Phase 4 will add user-facing window selection per SCK-02
- `coord.start()` is called after `makeKeyAndOrderFront` in AppDelegate — critical for satisfying TCC constraint that Screen Recording dialog must appear after a window is visible (Pitfall 4 from research)

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None - all 5 human-verification criteria passed on first run:
1. Permission dialog appeared after main window was visible
2. Window enumeration printed to console with count and dimensions
3. Frame logs arrived at ~60fps for both monitor slots
4. 10-minute run completed with no -3821 errors
5. Static-content windows produced a log timestamp gap but no crash or nil-texture error

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

Phase 1 complete. The capture foundation is ready for Phase 2 (Stereo Render Pipeline):
- `CaptureManager.texturePool.read(monitor:)` delivers `MTLTexture?` per slot — Phase 2 render loop reads from these
- `AppCoordinator` will be extended in Phase 4 to wire RenderEngine and TrackingProvider; the coordinator pattern is established
- **Phase 2 input:** TexturePool slots 0 and 1 are live with IOSurface-backed MTLTextures at 60fps

**Phase 3 risk reminder:** Viture macOS SDK may require macOS Sequoia 15+ — confirm deployment target before Phase 3 begins. Also verify SDK coordinate axis conventions empirically on hardware before writing any view matrix code.

---
*Phase: 01-capture-foundation*
*Completed: 2026-04-15*
