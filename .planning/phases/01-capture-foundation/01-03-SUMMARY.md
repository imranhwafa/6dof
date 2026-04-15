---
phase: 01-capture-foundation
plan: 03
subsystem: capture
tags: [screencapturekit, metal, corevideo, iosurface, triple-buffer, texture-pool]

# Dependency graph
requires:
  - 01-01 (SixDOF.xcodeproj with ScreenCaptureKit/CoreVideo/CoreMedia/Metal linked)
provides:
  - SixDOF/Capture/TexturePool.swift — NSLock-guarded triple-buffer texture hand-off
  - SixDOF/Capture/CaptureManager.swift — SCStreamOutput+SCStreamDelegate self-conformer with blit-and-release discipline
affects:
  - 01-capture-foundation/01-04 (WindowPicker feeds SCContentFilter to CaptureManager.startCapture)
  - 02-render-layer (renderer reads TexturePool via texturePool.read(monitor:))
  - 04-integration (AppCoordinator injects MTLDevice into CaptureManager init)

# Tech tracking
tech-stack:
  added:
    - CVMetalTextureCache (zero-copy IOSurface -> MTLTexture bridge)
    - CMSampleBuffer extraction via CMSampleBufferGetImageBuffer
    - MTLBlitCommandEncoder (GPU-to-GPU texture copy)
    - NSLock triple-buffer swap pattern
  patterns:
    - Self-conformer SCStreamOutput+SCStreamDelegate (avoids Pitfall 1 weak-ref dealloc)
    - Blit-and-release within captureOutput callback (prevents -3821 pool exhaustion)
    - CVMetalTexture retained via addCompletedHandler until GPU blit completes (Pitfall 6)
    - TexturePool.read() always returns last valid texture for SCK-04 static-content frames

key-files:
  created:
    - SixDOF/Capture/TexturePool.swift
    - SixDOF/Capture/CaptureManager.swift
  modified:
    - SixDOF.xcodeproj/project.pbxproj (added Capture group, two new source files)

key-decisions:
  - "TexturePool.ownedTexture(monitor:bufferIndex:) added as package-internal accessor — CaptureManager needs direct slot access for blit destination without going through read()"
  - "CaptureManager uses dedicated captureQueue DispatchQueue (label: com.app.sixdof.capture, qos: .userInteractive) — keeps blit processing off main thread"
  - "CVMetalTextureCache created once at CaptureManager init, not per-frame — prevents stale entry buildup and context creation overhead at 60fps"

requirements-completed:
  - SCK-03
  - SCK-04
  - ARC-03

# Metrics
duration: 6min
completed: 2026-04-15
---

# Phase 1 Plan 03: TexturePool and CaptureManager Summary

**NSLock-guarded triple-buffer TexturePool and SCStreamOutput/SCStreamDelegate self-conformer CaptureManager with IOSurface zero-copy blit-and-release pipeline at 60fps**

## Performance

- **Duration:** ~6 min
- **Started:** 2026-04-15T04:18:53Z
- **Completed:** 2026-04-15T04:24:XX Z
- **Tasks:** 2
- **Files created:** 2 Swift source files, 1 project file modified

## Accomplishments

- TexturePool: NSLock-guarded, 2 monitor slots, 3 owned MTLTexture buffers per slot, `.private` storageMode, write/read/ownedTexture/allocate methods — SCK-04 static-content frames handled by always returning last valid texture
- CaptureManager: self-conforms to SCStreamOutput + SCStreamDelegate; CVMetalTextureCache created once at init; processFrame() blits IOSurface-backed MTLTexture into owned pool texture via MTLBlitCommandEncoder; CVMetalTexture retained via addCompletedHandler until GPU completes (Pitfall 6); CMSampleBuffer released on return (Pitfall 2 / -3821 prevention); queueDepth=5, pixelFormat=32BGRA, dedicated captureQueue
- Both files added to SixDOF Xcode target under Capture group
- Build verified: BUILD SUCCEEDED (SYMROOT=/tmp/sixdof_build, build dir disk I/O issue is a persistent environment quirk — all prior builds also used this workaround)

## Task Commits

Each task was committed atomically:

1. **Task 1: Implement TexturePool with NSLock triple-buffer swap** — `1ebc4f3` (feat)
2. **Task 2: Implement CaptureManager with blit-and-release IOSurface discipline** — `8666cc2` (feat)

## TexturePool Design

- **Slot count:** 2 (index 0 = left monitor, index 1 = right monitor)
- **Buffer count per slot:** 3 (triple-buffer)
- **Storage mode:** `.private` — GPU-only, blit encoder writes here; CPU never touches these textures
- **Thread safety:** NSLock (`lock.withLock`) guards all slot access from both capture queue and render queue
- **SCK-04 handling:** `read(monitor:)` returns `slots[monitor][readIndices[monitor]]` — always the last successfully written texture. No new frame delivery from SCK (static window content) causes no nil, no freeze: renderer repeats the last valid texture.
- **Allocation:** `allocate(device:width:height:monitor:)` creates all 3 MTLTexture slots for a monitor at stream-start time, before any frame arrives

## CaptureManager Design

- **Queue label:** `com.app.sixdof.capture` (serial, `.userInteractive` QoS)
- **Blit pattern:** `CVMetalTextureCacheCreateTextureFromImage` → `makeBlitCommandEncoder` → `blit.copy(from:to:)` → `commandBuffer.commit()` — all within `processFrame()`, which is called from `captureOutput` on `captureQueue`. CMSampleBuffer and cvTexture references go out of scope before `captureOutput` returns.
- **CVMetalTexture retention:** `commandBuffer.addCompletedHandler` captures `cvTexture` via `capturedCVTexture` — IOSurface backing held until GPU blit completes, preventing Pitfall 6 corruption
- **Error handling:** `stream(_:didStopWithError:)` logs domain, code, description; -3821 gets a specific annotation flagging blit discipline as the probable cause
- **Stream management:** `streams: [Int: SCStream]` dictionary keyed by monitor slot index; `stream(_:didOutputSampleBuffer:of:)` reverse-looks up slot via `streams.first(where: { $0.value === stream })?.key`

## Files Created/Modified

- `SixDOF/Capture/TexturePool.swift` — new file, 95 lines
- `SixDOF/Capture/CaptureManager.swift` — new file, 172 lines
- `SixDOF.xcodeproj/project.pbxproj` — added Capture PBXGroup, 2 PBXFileReference, 2 PBXBuildFile, 2 Sources build phase entries

## Decisions Made

- **`ownedTexture(monitor:bufferIndex:)` added to TexturePool:** The plan called for CaptureManager to access pre-allocated textures by index as blit destinations. The cleanest way to do this without breaking TexturePool's encapsulation was an explicit accessor. Both TexturePool and CaptureManager are in the same module — this is an internal interface, not a public API.
- **`captureQueue` is serial, not concurrent:** Serial queue ensures blit operations for a given monitor slot run in FIFO order. A concurrent queue could allow overlapping blits to the same `writeIdx` slot. Serial eliminates that race at zero cost for 60fps single-monitor capture.
- **`writeIndices` keyed by monitor slot (dictionary):** The plan showed `[Int: Int]` to support the multi-stream architecture. Index 0 and 1 each have their own rotating write pointer, independently cycling 0→1→2→0.

## Deviations from Plan

None — plan executed exactly as written.

The `ownedTexture(monitor:bufferIndex:)` method was specified in the plan's Task 2 action block as an addition to TexturePool.swift: "Add a package-internal accessor to TexturePool if needed." It was added as specified. No deviation.

## Known Stubs

- `config.width = 1920` and `config.height = 1080` in `startCapture()` are hardcoded defaults. The plan explicitly notes: "WindowPicker will provide the correct dimensions in Plan 04." This stub is intentional and documented — it does not prevent the plan's goal (functional blit pipeline). Plan 04 will resolve this when SCContentFilter dimensions are available.

## Self-Check

- `SixDOF/Capture/TexturePool.swift` — FOUND
- `SixDOF/Capture/CaptureManager.swift` — FOUND
- Commit `1ebc4f3` — FOUND (feat(01-03): implement TexturePool)
- Commit `8666cc2` — FOUND (feat(01-03): implement CaptureManager)
- BUILD SUCCEEDED — CONFIRMED

## Self-Check: PASSED
