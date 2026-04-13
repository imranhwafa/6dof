# Claude Code Project Context — Viture Luma Ultra 6DOF XR

## Project Purpose

Unity XR development for the **Viture Luma Ultra** glasses — a 6DOF XR headset with proprietary on-device positional tracking, skeletal hand tracking, and gesture recognition. Uses the Viture Unity XR SDK (`com.viture.xr`) as a local UPM package.

---

## SDK

| Detail | Value |
|--------|-------|
| Package ID | `com.viture.xr` |
| Location | `Packages/com.viture.xr/` (local UPM package, committed to repo) |
| Docs | https://developer.viture.com/unity/viture_unity_xr_sdk_doc |

The Viture SDK is **not** on the Unity Registry — it must be present as a local package in `Packages/`. If it's missing, the project will fail to compile.

---

## Unity Requirements

- **Template:** Universal 3D (URP)
- **Unity Version:** 2022.3 LTS minimum; 6 LTS (6000.x) recommended
- **Required packages (Unity Registry):**
  - `com.unity.xr.interaction.toolkit` — XR Interaction Toolkit
  - `com.unity.xr.hands` — XR Hands
  - `com.viture.xr` — Viture SDK (local package in `Packages/`)
- **Build Target:** Android, API 29+, IL2CPP, ARM64
- **Rendering:** URP, Single Pass Instanced stereo mode

---

## Hardware Capabilities

- **6DOF Tracking:** Full positional + rotational head tracking via proprietary on-device chip. No external tracking hardware. Provided as a standard XR head pose.
- **Hand Tracking:** Skeletal hand tracking (full joint hierarchy) via Viture's XR Hands subsystem implementation.
- **Gestures:** Built-in gesture recognition (pinch, grab, point, etc.) from the Viture gesture API — separate from Unity's XR Hands joint data.

---

## Architecture

- **Player Rig:** `XROrigin` from XR Interaction Toolkit — standard setup, Viture's head tracking drives the camera automatically via the XR plug-in.
- **Rendering:** URP with Single Pass Instanced XR mode. URP renderer asset must have XR rendering enabled or the display will be wrong.
- **Hand Tracking:** `XRHandSubsystem` from XR Hands package, backed by Viture's subsystem implementation registered via the SDK.
- **Gestures:** Viture SDK gesture API on top of skeletal data — event-driven, see `Assets/Scripts/Gestures/`.
- **Input:** Prefer XR Interaction Toolkit (`IXRInteractor`, `XRRayInteractor`, `XRDirectInteractor`) over raw `InputDevice` APIs for interaction logic.

---

## File Layout

```
Assets/
  Scenes/         — Unity scenes (Main.unity is entry point)
  Scripts/
    XR/           — Device/subsystem interaction scripts
    Gestures/     — Viture gesture API wrappers
    UI/           — Spatial UI logic
  Prefabs/
    Hands/        — Hand tracking rigs
    UI/           — Spatial panels and menus
  Materials/      — URP materials
  Settings/       — URP renderer asset, XR settings asset
  XR/             — XR interaction profiles, input action maps
Packages/
  com.viture.xr/  — Viture XR SDK (local UPM package)
ProjectSettings/  — Committed to repo (XR Plug-in Management config lives here)
Docs/             — Architecture decisions, SDK research notes
```

Scripts use namespaces matching their folder hierarchy (e.g., `Scripts/XR/` → `namespace Project.XR`).

---

## Key Workflows

### New scene
1. Create scene in `Assets/Scenes/`
2. Add `XROrigin` prefab as player rig
3. Assign URP camera settings asset to Camera component
4. Configure URP renderer for Single Pass Instanced if not inheriting from Settings

### Hand tracking integration
1. Confirm `com.viture.xr` and `com.unity.xr.hands` are installed
2. Enable Viture hand tracking subsystem in **Project Settings → XR Hands**
3. Use `XRHandSubsystem` API for joint data; use Viture gesture API for gesture events
4. Hand tracking rigs live in `Assets/Prefabs/Hands/`

### Building to device
1. **File → Build Settings** → switch to Android
2. Confirm XR Plug-in Management has Viture XR enabled for Android
3. Enable IL2CPP + ARM64 in **Player Settings**
4. Build and deploy via adb or Unity's Build & Run

---

## Important Caveats for Claude

- **Don't assume standard OpenXR APIs work identically.** The Viture SDK wraps some inputs differently. Check `com.viture.xr` docs before referencing OpenXR extension paths.
- **Gesture API is proprietary** — it lives in the Viture SDK namespace, not in `UnityEngine.XR.Hands`. Don't conflate the two.
- **Library/, Temp/, Build/ are gitignored** — don't reference or create files there.
- **`ProjectSettings/` is committed** — changes to XR Plug-in Management, URP settings, etc. will show in git diff. Treat them as code.
- **URP renderer asset must have XR enabled** — if stereo rendering looks broken, check the URP renderer asset first.
