# Viture Luma Ultra 6DOF Development

Unity XR project targeting the **Viture Luma Ultra** glasses with their proprietary 6DOF dev kit. Covers application development using the Viture XR SDK, hand tracking, skeletal gestures, and spatial computing on the Luma Ultra hardware.

---

## Hardware

**Viture Luma Ultra XR Glasses**
- Proprietary on-device 6DOF chip — full positional + rotational tracking, no external base station
- Skeletal hand tracking with gesture recognition (pinch, grab, point, etc.)
- USB-C connection to compute host (Android phone, PC, or dedicated compute module)

**6DOF Dev Kit**
- Unlocks full 6DOF positional + rotational tracking APIs
- Required for head pose, hand pose, and spatial anchor features

---

## Prerequisites

| Requirement | Version / Notes |
|---|---|
| Unity Editor | 6 LTS (6000.x) recommended; 2022.3 LTS minimum |
| Render Pipeline | Universal Render Pipeline (URP) — required |
| XR Interaction Toolkit | Install from Unity Registry |
| XR Hands | Install from Unity Registry |
| Viture XR SDK | `com.viture.xr` — place in `Packages/` |
| Android Build Support | Target API 29+ |

---

## Project Setup

### 1. Create Unity Project

Open Unity Hub → **New Project** → **Universal 3D** template.

### 2. Install Registry Packages

**Window → Package Manager → Unity Registry**, install:
- `XR Interaction Toolkit`
- `XR Hands`

### 3. Install the Viture XR SDK

Copy the Viture SDK into the `Packages/` directory:

```
Packages/
  com.viture.xr/         ← SDK goes here
    package.json
    Runtime/
    Editor/
```

The SDK directory is tracked in git so it ships with the project.

### 4. Configure XR Plug-in Management

- **Edit → Project Settings → XR Plug-in Management**
- Enable **Viture XR** on the Android tab
- Set **Stereo Rendering Mode** to Single Pass Instanced

### 5. Build Target

- Platform: **Android**
- Minimum API Level: 29
- Scripting Backend: IL2CPP
- Target Architecture: ARM64

---

## Project Structure

```
Assets/
  Scenes/          # Unity scenes
    Main.unity     # Entry point scene
  Scripts/
    XR/            # XR / device interaction
    Gestures/      # Hand gesture handling
    UI/            # Spatial UI controllers
  Prefabs/
    Hands/         # Hand tracking rigs
    UI/            # Spatial panels, menus
  Materials/       # URP materials and shaders
  Settings/        # URP renderer asset, XR settings
  XR/              # XR interaction profiles and configs
Packages/
  com.viture.xr/   # Viture XR SDK (local UPM package)
  manifest.json
ProjectSettings/   # Committed — keeps XR config in sync
Docs/              # Architecture notes, SDK findings
```

---

## Key Development Concepts

### 6DOF Head Tracking

The Luma Ultra handles 6DOF on-device. Head pose is available via the standard XR Input subsystem once the Viture plug-in is enabled:

```csharp
using UnityEngine.XR;

var headDevice = InputDevices.GetDeviceAtXRNode(XRNode.Head);
headDevice.TryGetFeatureValue(CommonUsages.devicePosition, out Vector3 pos);
headDevice.TryGetFeatureValue(CommonUsages.deviceRotation, out Quaternion rot);
```

Or use the **XROrigin** rig from XR Interaction Toolkit — it handles head tracking automatically via the Camera Offset + Main Camera hierarchy.

### Hand Tracking

```csharp
using UnityEngine.XR.Hands;

var handSubsystems = new List<XRHandSubsystem>();
SubsystemManager.GetSubsystems(handSubsystems);
var subsystem = handSubsystems[0];
subsystem.Start();

// Per-frame joint access
XRHand hand = subsystem.leftHand;
if (hand.GetJoint(XRHandJointID.IndexTip, out XRHandJoint joint))
    joint.TryGetPose(out Pose tipPose);
```

### Gestures

The Viture SDK layers gesture recognition on top of skeletal data. See `Assets/Scripts/Gestures/` for event-driven wrappers around the Viture gesture API.

---

## Resources

| Resource | URL |
|---|---|
| Viture Developer Portal | https://developer.viture.com |
| Viture Unity XR SDK Docs | https://developer.viture.com/unity/viture_unity_xr_sdk_doc |
| XR Interaction Toolkit Docs | https://docs.unity3d.com/Packages/com.unity.xr.interaction.toolkit@latest |
| XR Hands Docs | https://docs.unity3d.com/Packages/com.unity.xr.hands@latest |
| URP Docs | https://docs.unity3d.com/Packages/com.unity.render-pipelines.universal@latest |

---

## Branch Workflow

```
feature/<name>  →  main
```

- Work on feature branches
- Test on-device before merging (Viture hardware required for full validation)
- Keep `ProjectSettings/` committed so XR config stays in sync across machines
