# macOS XR Desktop (Viture Luma Ultra)

## What This Is

A native macOS app that renders 2 virtual floating monitors in 3D space using ScreenCaptureKit for live window capture and Metal for GPU-accelerated 3D rendering. Designed for the Viture Luma Ultra XR glasses, pulling head-pose data from the Viture macOS SDK to keep monitors locked in world space as the user moves their head. Architecture is modular to support full 6DOF positional tracking in later milestones.

## Core Value

Two live macOS windows rendered as stable 3D quads in the Viture display — head moves, monitors stay fixed in space.

## Requirements

### Validated

(None yet — ship to validate)

### Active

- [ ] App captures live macOS window content via ScreenCaptureKit
- [ ] App renders 2 floating monitor quads in 3D using Metal
- [ ] Viture macOS SDK drives head orientation (yaw/pitch/roll) in real time
- [ ] Virtual monitors remain fixed in world space as head rotates
- [ ] Stereo output rendered correctly for Viture Luma Ultra display
- [ ] Architecture cleanly separates capture, rendering, and tracking layers for 6DOF extensibility

### Out of Scope

- Linux code or Breezy Desktop port — macOS-native from scratch
- Unity — this is a native macOS app, not a game engine project
- Click-through / raycasting interaction — v2
- Positional (6DOF) tracking — v2 (architecture prepared, not implemented)
- Spatial cursor / hand tracking — v2+
- Multi-monitor configuration UI — v2

## Context

- Inspired by Breezy Desktop (https://github.com/wheaney/breezy-desktop) — a Linux X11/Wayland XR desktop. Do NOT port its code.
- Viture provides a macOS SDK (separate from the Unity XR package) that exposes head-pose quaternion/Euler data.
- ScreenCaptureKit (macOS 12.3+) is the modern API for capturing live window and screen content with minimal latency.
- Metal is used for all 3D rendering — no SceneKit, no RealityKit, direct GPU pipeline.
- The repo previously scaffolded a Unity XR project for Viture Luma Ultra; that scaffold is superseded by this native macOS app.

## Constraints

- **Platform**: macOS 13+ — ScreenCaptureKit SCStreamConfiguration requires macOS 13 for best stream control
- **Language**: Swift + Metal — no Objective-C, no Linux, no cross-platform abstraction
- **Hardware**: Viture Luma Ultra — stereo display must respect device's optical parameters (IPD, lens distortion if applicable)
- **Architecture**: Capture / Render / Tracking modules must be protocol-backed interfaces so 6DOF positional tracking can be dropped in without rewiring rendering

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| ScreenCaptureKit over CGDisplayStream | Modern API, lower latency, per-window capture | — Pending |
| Metal over SceneKit/RealityKit | Full control over stereo pipeline, no framework assumptions | — Pending |
| Viture macOS SDK (not Unity SDK) | Native macOS app — Unity SDK not applicable outside game engine | — Pending |
| World-locked monitors (no follow) | Matches Breezy's default mode, simpler v1 tracking math | — Pending |
| Modular layer architecture | Enables 6DOF drop-in without refactoring rendering | — Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd:transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd:complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-04-14 after initialization*
