# Viture Luma Ultra 6DOF XR Development

Unity XR project for developing 6DOF experiences on the Viture Luma Ultra XR glasses.

## Overview

The Viture Luma Ultra features a proprietary on-device 6DOF chip enabling full positional and rotational tracking. This project targets native XR development using Viture's Unity SDK.

## SDK

- **Package ID:** `com.viture.xr`
- **Location:** Place the SDK in the Unity `Packages/` directory (as a local package or via UPM)
- **Docs:** https://developer.viture.com/unity/viture_unity_xr_sdk_doc

## Unity Setup

1. **Template:** Universal 3D (URP recommended)
2. **Required Packages (via Package Manager):**
   - XR Interaction Toolkit
   - XR Hands
   - `com.viture.xr` (local Packages/ folder)
3. **Project Settings → XR Plug-in Management:** Enable Viture XR plugin for target platform

## 6DOF Capabilities

- **Tracking:** Proprietary on-device chip — full 6DOF (position + rotation)
- **Hand Tracking:** Skeletal hand tracking with gesture recognition
- **Hand Gestures:** Supported natively via XR Hands integration

## Directory Structure

```
Assets/
  Scripts/       — C# game logic
  Scenes/        — Unity scenes
  Prefabs/       — Reusable prefabs
  Materials/     — Materials and shaders
  XR/            — XR-specific configs, interaction profiles
Packages/        — UPM packages (including com.viture.xr)
ProjectSettings/ — Unity project settings
```

## Development Notes

- URP pipeline asset must be configured for XR (Single Pass Instanced recommended)
- Use XR Interaction Toolkit's XROrigin rig as the base player setup
- Hand tracking requires XR Hands package and Viture SDK hand subsystem enabled
- Build target: Android (for standalone on-device) or PC (tethered)
