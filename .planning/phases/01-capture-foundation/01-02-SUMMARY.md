---
phase: 01-capture-foundation
plan: 02
subsystem: permissions
tags: [screencapturekit, tcc, macos-permissions, swift, appkit]

# Dependency graph
requires:
  - phase: 01-capture-foundation/01-01
    provides: AppDelegate scaffolding with NSWindow visible before SCK calls
provides:
  - PermissionGateway class with Status enum (granted/denied/notDetermined)
  - TCC probe via SCShareableContent.excludingDesktopWindows
  - Async requestPermission() method deferred to post-window-visible
  - Denied-state NSAlert recovery path with System Settings deep-link
affects:
  - 01-capture-foundation/01-04 (CaptureManager start gated behind PermissionGateway)
  - 01-capture-foundation/01-05 (AppCoordinator wires permission into capture pipeline)

# Tech tracking
tech-stack:
  added: [ScreenCaptureKit (TCC probe only, no stream yet)]
  patterns:
    - "TCC probe via SCShareableContent.excludingDesktopWindows — no private APIs, notarization-safe"
    - "Permission deferred to Task after makeKeyAndOrderFront — avoids Pitfall 4"
    - "SCStreamError.userDeclined catch for denied vs notDetermined discrimination"

key-files:
  created:
    - SixDOF/Permissions/PermissionGateway.swift
  modified:
    - SixDOF/AppDelegate.swift
    - SixDOF.xcodeproj/project.pbxproj

key-decisions:
  - "showDeniedAlert() is @MainActor and terminates app — denied state is unrecoverable without relaunch"
  - "NSScreenCaptureUsageDescription already present in Info.plist from Plan 01; no change needed"
  - "Permission requested in Task { @MainActor } block after makeKeyAndOrderFront — Pitfall 4 pattern exactly followed"

patterns-established:
  - "Pattern: PermissionGateway.currentStatus() is the canonical TCC probe — call before any SCK API"
  - "Pattern: requestPermission() return value gates CaptureManager.start() — never start capture without checking"

requirements-completed: [SCK-01]

# Metrics
duration: 3min
completed: 2026-04-15
---

# Phase 01 Plan 02: PermissionGateway Summary

**macOS Screen Recording TCC probe via SCShareableContent with async Status enum, denied-state NSAlert recovery path linking to System Settings, and AppDelegate wiring after window is visible**

## Performance

- **Duration:** ~3 min
- **Started:** 2026-04-15T04:17:44Z
- **Completed:** 2026-04-15T04:20:30Z
- **Tasks:** 1
- **Files modified:** 3

## Accomplishments
- PermissionGateway.swift created with Status enum (granted/denied/notDetermined), SCShareableContent TCC probe, and async requestPermission() with denied-state recovery
- Denied state shows NSAlert "Screen Recording Access Required" with "Open System Settings" button deep-linking to Privacy_ScreenCapture and app termination
- AppDelegate wires requestPermission() in a Task block after makeKeyAndOrderFront — Pitfall 4 (dialog before window) strictly avoided
- Xcode project.pbxproj updated with Permissions group and PermissionGateway.swift in Sources build phase
- BUILD SUCCEEDED

## Task Commits

Each task was committed atomically:

1. **Task 1: Implement PermissionGateway with TCC probe and denied-state handling** - `e8d3efa` (feat)

**Plan metadata:** (docs commit below)

## Files Created/Modified
- `SixDOF/Permissions/PermissionGateway.swift` - PermissionGateway class: Status enum, currentStatus() TCC probe, requestPermission() async method, showDeniedAlert() @MainActor recovery
- `SixDOF/AppDelegate.swift` - Added permissionGateway property; Task block after makeKeyAndOrderFront calls requestPermission()
- `SixDOF.xcodeproj/project.pbxproj` - Permissions group added; PermissionGateway.swift registered as PBXFileReference and PBXBuildFile in Sources

## Decisions Made
- showDeniedAlert() terminates the app regardless of user action — this is correct since the app cannot function without Screen Recording permission. The "Quit" button and the System Settings path both call NSApplication.shared.terminate(nil).
- NSScreenCaptureUsageDescription was already present in Info.plist from Plan 01 — no change needed.

## Deviations from Plan

None — plan executed exactly as written.

## Issues Encountered
- `xcodebuild` failed with disk I/O error on the worktree's default build directory. Resolved by passing `SYMROOT=/tmp/sixdof-build-02` to redirect the build database. This is a worktree environment artifact, not a code issue.

## User Setup Required
None — no external service configuration required.

## Next Phase Readiness
- PermissionGateway is complete and buildable
- Plan 03 (WindowPicker / SCShareableContent enumeration) can now safely call SCShareableContent because PermissionGateway.requestPermission() will have run first
- Plan 04 (CaptureManager) should gate SCStream.startCapture() behind PermissionGateway.currentStatus() == .granted

---
*Phase: 01-capture-foundation*
*Completed: 2026-04-15*
