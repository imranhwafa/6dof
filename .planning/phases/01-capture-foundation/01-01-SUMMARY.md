---
phase: 01-capture-foundation
plan: 01
subsystem: infra
tags: [xcode, swift, appkit, screencapturekit, metal, corevideo, coremedia, macos]

# Dependency graph
requires: []
provides:
  - SixDOF.xcodeproj — macOS App target, AppKit lifecycle, macOS 13.0 minimum, Swift 5.9
  - SixDOF/main.swift — NSApplication entry point
  - SixDOF/AppDelegate.swift — NSApplicationDelegate with visible NSWindow before any SCK calls
  - SixDOF/Info.plist — NSScreenCaptureUsageDescription for TCC permission dialog
  - Linked frameworks: ScreenCaptureKit, CoreVideo, CoreMedia, Metal
affects:
  - 01-capture-foundation (all subsequent plans depend on this buildable project)
  - 02-permission-gateway
  - 03-capture-manager
  - 04-texture-pool

# Tech tracking
tech-stack:
  added:
    - Xcode 26.3 (project target)
    - Swift 5.9 (SWIFT_VERSION)
    - ScreenCaptureKit.framework (linked, weak)
    - CoreVideo.framework (linked)
    - CoreMedia.framework (linked)
    - Metal.framework (linked)
  patterns:
    - AppKit NSApplicationDelegate lifecycle (no SwiftUI, no @main)
    - NSWindow created in applicationDidFinishLaunching before any SCK calls
    - SWIFT_STRICT_CONCURRENCY = minimal (Phase 1 uses NSLock, not Swift concurrency)

key-files:
  created:
    - SixDOF.xcodeproj/project.pbxproj
    - SixDOF/main.swift
    - SixDOF/AppDelegate.swift
    - SixDOF/Info.plist
  modified: []

key-decisions:
  - "Manual project.pbxproj creation (xcodegen not installed, sudo unavailable in agent environment)"
  - "SWIFT_STRICT_CONCURRENCY=minimal to match Phase 1 NSLock threading model"
  - "NSWindow created before permission flow — required by SCK TCC pattern"
  - "ScreenCaptureKit linked as Weak to allow macOS 13 minimum deployment target"

patterns-established:
  - "AppKit lifecycle: NSApplication.shared.delegate = AppDelegate() in main.swift"
  - "Permission gate: window must be visible before any SCK API call"

requirements-completed:
  - SCK-01

# Metrics
duration: 3min
completed: 2026-04-15
---

# Phase 1 Plan 01: Xcode Project Scaffold Summary

**macOS App target built — AppKit lifecycle, macOS 13.0, Swift 5.9, strict concurrency off, ScreenCaptureKit/CoreVideo/CoreMedia/Metal linked, NSScreenCaptureUsageDescription in Info.plist**

## Performance

- **Duration:** ~3 min
- **Started:** 2026-04-15T04:14:39Z
- **Completed:** 2026-04-15T04:17:12Z
- **Tasks:** 2
- **Files modified:** 4 created, 0 modified

## Accomplishments

- SixDOF.xcodeproj created manually (xcodegen not available) with correct AppKit lifecycle, macOS 13.0 deployment target, SWIFT_STRICT_CONCURRENCY=minimal
- All four required frameworks linked: ScreenCaptureKit (weak), CoreVideo, CoreMedia, Metal
- NSScreenCaptureUsageDescription added to Info.plist with appropriate user-facing reason string
- Build verified: `xcodebuild -project SixDOF.xcodeproj -target SixDOF -configuration Debug build` → BUILD SUCCEEDED

## Task Commits

Each task was committed atomically:

1. **Task 1: Create Xcode project with AppKit lifecycle and correct build settings** - `f39f4ea` (feat)
2. **Task 2: Add NSScreenCaptureUsageDescription and linked frameworks to project** - `fd30aea` (feat)

**Plan metadata:** (docs commit follows)

## Files Created/Modified

- `SixDOF.xcodeproj/project.pbxproj` — macOS App target, AppKit, macOS 13.0, Swift 5.9, SWIFT_STRICT_CONCURRENCY=minimal, four frameworks linked
- `SixDOF/main.swift` — NSApplication.shared entry point, delegates to AppDelegate()
- `SixDOF/AppDelegate.swift` — NSApplicationDelegate, creates NSWindow in applicationDidFinishLaunching
- `SixDOF/Info.plist` — Standard macOS app plist + NSScreenCaptureUsageDescription key

## Decisions Made

- **Manual project creation:** xcodegen is not installed and sudo is unavailable in this environment. Created project.pbxproj directly with all required settings. No deviation in outcome — all plan acceptance criteria met.
- **ScreenCaptureKit linked as Weak:** ScreenCaptureKit exists on all macOS 12.3+ systems but marking it weak avoids linker errors if the deployment target is ever tested below the framework's availability. Correct practice for optional system frameworks.
- **SWIFT_STRICT_CONCURRENCY=minimal:** Per plan and research — Phase 1 uses NSLock-guarded TexturePool; strict concurrency checking would require @Sendable annotations throughout the capture pipeline before it's written. Keeping minimal unblocks Phase 1 execution.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Manual project.pbxproj creation (xcodegen unavailable)**
- **Found during:** Task 1 (Create Xcode project)
- **Issue:** Plan preferred xcodegen but it was not installed, and sudo (required to install via Homebrew) is unavailable in the agent environment
- **Fix:** Created SixDOF.xcodeproj/project.pbxproj directly with all required settings — deployment target 13.0, SWIFT_STRICT_CONCURRENCY=minimal, four frameworks linked, Info.plist path configured
- **Files modified:** SixDOF.xcodeproj/project.pbxproj
- **Verification:** `xcodebuild -project SixDOF.xcodeproj -target SixDOF -configuration Debug build` → BUILD SUCCEEDED
- **Committed in:** f39f4ea (Task 1 commit)

---

**Total deviations:** 1 auto-fixed (1 blocking — tooling unavailability)
**Impact on plan:** No impact on outcome. All acceptance criteria met. Manual .pbxproj achieves identical result to xcodegen-generated file.

## Issues Encountered

- `ONLY_ACTIVE_ARCH=YES` warning with `-destination "platform=macOS"` flag: xcodebuild couldn't resolve the active arch in agent environment. Resolved by dropping the `-destination` flag — the warning is benign and BUILD SUCCEEDED is confirmed.
- Build directory disk I/O error on first attempt with `-destination` flag. Same resolution — dropped the flag.

## User Setup Required

None — no external service configuration required. Project builds locally without any credentials or external dependencies.

## Next Phase Readiness

- SixDOF.xcodeproj is buildable and ready for all Phase 1 follow-on plans
- AppDelegate is the integration point for Plan 02 (PermissionGateway)
- All required frameworks are linked — CaptureManager (Plan 03) can import ScreenCaptureKit immediately
- NSScreenCaptureUsageDescription is present — TCC permission dialog will function correctly on a clean install

---
*Phase: 01-capture-foundation*
*Completed: 2026-04-15*
