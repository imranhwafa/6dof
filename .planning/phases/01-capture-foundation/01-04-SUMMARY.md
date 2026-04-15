---
phase: 01-capture-foundation
plan: "04"
subsystem: capture
tags: [screen-capture, sckit, window-enumeration, content-filter]
dependency_graph:
  requires:
    - 01-02  # PermissionGateway (.granted required before WindowPicker.availableWindows())
    - 01-03  # CaptureManager (startCapture(filter:monitorSlot:) consumer of WindowPicker.filter(for:))
  provides:
    - WindowPicker.availableWindows() — SCWindow enumeration via SCShareableContent
    - WindowPicker.filter(for:) — SCContentFilter factory for per-window capture
    - WindowPicker.pixelSize(for:) — logical-to-pixel conversion for SCStreamConfiguration
  affects:
    - 01-05  # AppDelegate wires PermissionGateway + WindowPicker + CaptureManager together
tech_stack:
  added:
    - SCShareableContent (ScreenCaptureKit) — window enumeration
    - SCContentFilter(desktopIndependentWindow:) — per-window capture filter
  patterns:
    - Filter factory pattern: WindowPicker.filter(for:) decouples enumeration from capture
    - Value-type wrapper: WindowInfo(Identifiable) over SCWindow for clean API surface
key_files:
  created:
    - SixDOF/Capture/WindowPicker.swift
  modified:
    - SixDOF.xcodeproj/project.pbxproj
decisions:
  - "SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) used for enumeration — same call as PermissionGateway.currentStatus(), avoids CGWindowListCreateImage (deprecated macOS 14, extra TCC prompts macOS 15)"
  - "SCContentFilter(desktopIndependentWindow:) chosen over display-based filter — captures exactly one window regardless of display layout, correct for SCK-02 window-picker UX"
  - "pixelSize(for:) uses NSScreen.main?.backingScaleFactor — SCStreamConfiguration.width/height requires pixels not logical points"
metrics:
  duration: "2 minutes"
  completed: "2026-04-15T04:26:26Z"
  tasks_completed: 1
  files_created: 1
  files_modified: 1
---

# Phase 01 Plan 04: WindowPicker Summary

WindowPicker window enumeration and SCContentFilter factory using SCShareableContent (not deprecated CGWindowListCreateImage). Separates window selection from capture: CaptureManager receives only SCContentFilter, WindowPicker owns enumeration and filter construction.

## What Was Built

`SixDOF/Capture/WindowPicker.swift` — a final class with three public methods:

- `availableWindows() async throws -> [WindowInfo]` — calls `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)`, filters to on-screen windows with non-empty titles, maps to `WindowInfo` structs sorted by app name
- `filter(for:) -> SCContentFilter` — constructs `SCContentFilter(desktopIndependentWindow:)` for the selected window
- `pixelSize(for:) -> (width: Int, height: Int)` — multiplies logical frame dimensions by `NSScreen.main?.backingScaleFactor` for correct `SCStreamConfiguration.width/height` pixel values

`WindowInfo` struct fields: `id: UInt32` (windowID), `title: String`, `appName: String`, `frame: CGRect`, `scWindow: SCWindow`, computed `displayName: String` ("\(appName) — \(title)").

## API Choices

| API Used | Alternative | Reason |
|---|---|---|
| `SCShareableContent.excludingDesktopWindows` | `CGWindowListCreateImage` | Deprecated macOS 14; triggers extra TCC prompts macOS 15 |
| `SCContentFilter(desktopIndependentWindow:)` | Display-based filter | Per-window capture regardless of display layout — correct for SCK-02 |
| `NSScreen.main?.backingScaleFactor` | Hardcoded scale | Correct on both standard and Retina displays |

## Verification

Build result: **BUILD SUCCEEDED** (xcodebuild -project SixDOF.xcodeproj -target SixDOF -configuration Debug build)

All acceptance criteria passed:
- `class WindowPicker` — present
- `struct WindowInfo` — present
- `func availableWindows` — present
- `SCShareableContent.excludingDesktopWindows` — present (correct API)
- `SCContentFilter(desktopIndependentWindow:)` — present (per-window filter)
- `func filter(for` — present
- `func pixelSize` — present
- `CGWindowList` / `CGWindowListCreateImage` — absent from code (doc comment only, no actual usage)

## Deviations from Plan

None — plan executed exactly as written.

## Known Stubs

None — WindowPicker is a pure enumeration and filter factory. No data flows to UI rendering in this plan (console printing wired in 01-05).

## Commits

| Task | Description | Hash | Files |
|------|-------------|------|-------|
| 1 | Implement WindowPicker with SCShareableContent enumeration and SCContentFilter factory | c22072c | SixDOF/Capture/WindowPicker.swift, SixDOF.xcodeproj/project.pbxproj |

## Self-Check: PASSED
