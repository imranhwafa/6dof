# Claude Code Project Context — Viture Luma Ultra 6DOF XR

## Project Purpose

Unity XR development for the **Viture Luma Ultra** glasses — a 6DOF XR headset with proprietary on-device positional tracking, skeletal hand tracking, and gesture recognition.

## SDK

| Detail | Value |
|--------|-------|
| Package ID | `com.viture.xr` |
| Location | `Packages/` directory (local UPM package) |
| Docs | https://developer.viture.com/unity/viture_unity_xr_sdk_doc |

## Unity Requirements

- **Template:** Universal 3D (URP)
- **Unity Version:** 2022.3 LTS or newer recommended
- **Required packages:**
  - `com.unity.xr.interaction.toolkit` (XR Interaction Toolkit)
  - `com.unity.xr.hands` (XR Hands)
  - `com.viture.xr` (Viture SDK — local package in Packages/)

## Architecture

- **Player Rig:** XROrigin from XR Interaction Toolkit
- **Rendering:** URP with Single Pass Instanced XR rendering
- **Hand Tracking:** XR Hands subsystem backed by Viture SDK
- **Gestures:** Available via Viture SDK — pinch, grab, and custom gestures

## Key Workflows

### Adding a new scene
1. Create scene in `Assets/Scenes/`
2. Add XROrigin prefab as player rig
3. Configure URP camera settings for XR

### Hand tracking setup
1. Enable XR Hands in Project Settings → XR Plug-in Management
2. Use `XRHand` and `XRHandSubsystem` APIs
3. Viture SDK provides the hand subsystem — ensure it's listed in XR Hands settings

### Building
- **Target Platform:** Android (standalone on-device) or Windows/Mac (tethered)
- Enable XR plug-in for target platform in Project Settings → XR Plug-in Management

## File Conventions

- Scripts: `Assets/Scripts/` — use namespaces matching folder hierarchy
- XR configs/profiles: `Assets/XR/`
- No `Library/`, `Temp/`, `Build/` directories committed (gitignored)

## Notes for Claude

- Always check `com.viture.xr` SDK docs before assuming standard OpenXR APIs work identically
- Hand gesture API is proprietary — look in the Viture SDK namespace, not Unity's
- When writing XR interaction code, prefer XR Interaction Toolkit abstractions over direct device APIs
- URP asset must have XR rendering enabled or the display will render incorrectly
