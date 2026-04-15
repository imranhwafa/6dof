import ScreenCaptureKit
import Metal
import Foundation
import AppKit

/// Orchestrates the Phase 1 capture pipeline.
///
/// Owns PermissionGateway, WindowPicker, and CaptureManager.
/// Called from AppDelegate after the main window is visible.
///
/// Phase 1 behaviour (no UI picker yet):
///   1. Request Screen Recording permission
///   2. On .granted: enumerate windows, log list, start capture on first two available windows
///   3. Log frame arrivals to console at ~60fps to prove pipeline is live
///   4. On .denied: PermissionGateway handles the alert and exits
@MainActor
final class AppCoordinator {

    private let permissionGateway = PermissionGateway()
    private let windowPicker = WindowPicker()
    private let captureManager = CaptureManager()

    /// Begin the permission → capture pipeline.
    /// Must be called after the main window is visible on screen.
    func start() {
        Task {
            await run()
        }
    }

    private func run() async {
        // Step 1: Permission gate
        let status = await permissionGateway.requestPermission()
        guard status == .granted else {
            // PermissionGateway handles the denied alert and calls NSApplication.terminate
            return
        }

        print("[AppCoordinator] Permission granted — enumerating windows")

        // Step 2: Enumerate available windows
        let windows: [WindowPicker.WindowInfo]
        do {
            windows = try await windowPicker.availableWindows()
        } catch {
            print("[AppCoordinator] Failed to enumerate windows: \(error)")
            return
        }

        print("[AppCoordinator] Available windows (\(windows.count) total):")
        for (index, window) in windows.enumerated() {
            print("  [\(index)] \(window.displayName) — \(Int(window.frame.width))x\(Int(window.frame.height))")
        }

        guard windows.count >= 1 else {
            print("[AppCoordinator] No capturable windows found — is Screen Recording granted?")
            return
        }

        // Step 3: Start capture for up to 2 windows (slots 0 and 1)
        // Phase 1: Use first available windows for pipeline verification.
        // Phase 4 will add a UI picker (SCK-02 full UX).
        let slot0Window = windows[0]
        let slot1Window = windows.count > 1 ? windows[1] : windows[0]

        print("[AppCoordinator] Starting capture — slot 0: \(slot0Window.displayName)")
        print("[AppCoordinator] Starting capture — slot 1: \(slot1Window.displayName)")

        do {
            // startCapture allocates TexturePool internally using CaptureManager's own device
            try await captureManager.startCapture(
                filter: windowPicker.filter(for: slot0Window),
                monitorSlot: 0
            )

            try await captureManager.startCapture(
                filter: windowPicker.filter(for: slot1Window),
                monitorSlot: 1
            )
        } catch {
            print("[AppCoordinator] Failed to start capture: \(error)")
            return
        }

        print("[AppCoordinator] Both capture streams started — monitoring for 10 minutes")
        print("[AppCoordinator] Watch for: frame logs, -3821 errors, static-content gaps")

        // Phase 1 pipeline runs via CaptureManager callbacks.
        // Frame arrival is logged in CaptureManager.processFrame.
        // No render loop yet — TexturePool.read() will be exercised in Phase 2.
    }
}
