import ScreenCaptureKit
import AppKit

/// Gates all SCStream and SCShareableContent usage behind macOS Screen Recording permission.
/// Call requestPermission() only after the main window is visible on screen.
final class PermissionGateway {

    enum Status {
        case granted
        case denied
        case notDetermined
    }

    /// Probes current TCC permission status without showing a dialog.
    /// Uses a minimal SCShareableContent call — the only reliable probe without
    /// triggering a second TCC dialog.
    func currentStatus() async -> Status {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return .granted
        } catch let error as SCStreamError where error.code == .userDeclined {
            return .denied
        } catch {
            // Any other error: treat as not determined (may still show dialog on request)
            return .notDetermined
        }
    }

    /// Requests permission if not yet granted. The first call to SCShareableContent
    /// triggers the TCC dialog. Must be called after the main window is visible.
    /// Returns the resulting status.
    @discardableResult
    func requestPermission() async -> Status {
        let status = await currentStatus()
        switch status {
        case .granted:
            return .granted
        case .denied:
            await showDeniedAlert()
            return .denied
        case .notDetermined:
            // currentStatus() already triggered the TCC probe — if the dialog appeared
            // and the user responded, the next call will reflect their choice.
            let updated = await currentStatus()
            if case .denied = updated {
                await showDeniedAlert()
            }
            return updated
        }
    }

    @MainActor
    private func showDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording Access Required"
        alert.informativeText = """
            SixDOF needs Screen Recording permission to capture your windows.

            To grant access:
            1. Open System Settings → Privacy & Security → Screen Recording
            2. Enable SixDOF in the list
            3. Relaunch the app

            Without this permission, no windows can be captured.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            )
        }
        NSApplication.shared.terminate(nil)
    }
}
