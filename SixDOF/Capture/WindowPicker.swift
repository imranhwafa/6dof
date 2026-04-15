import ScreenCaptureKit
import AppKit
import Foundation

/// Enumerates capturable macOS windows and constructs SCContentFilter instances.
///
/// Must only be called after PermissionGateway reports .granted status.
/// Uses SCShareableContent (not CGWindowListCreateImage — deprecated macOS 14).
final class WindowPicker {

    // MARK: - WindowInfo

    /// Display-ready wrapper around SCWindow.
    struct WindowInfo: Identifiable {
        let id: UInt32        // SCWindow.windowID
        let title: String
        let appName: String
        let frame: CGRect
        let scWindow: SCWindow

        var displayName: String {
            "\(appName) — \(title)"
        }
    }

    // MARK: - Enumeration

    /// Returns all on-screen windows with non-empty titles.
    ///
    /// Filters out windows with no title (system UI, menu bar extras) to reduce noise.
    /// Must be called after Screen Recording permission is granted.
    func availableWindows() async throws -> [WindowInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        return content.windows
            .filter { window in
                guard let title = window.title, !title.isEmpty else { return false }
                return window.isOnScreen
            }
            .map { window in
                WindowInfo(
                    id: window.windowID,
                    title: window.title ?? "(untitled)",
                    appName: window.owningApplication?.applicationName ?? "(unknown app)",
                    frame: window.frame,
                    scWindow: window
                )
            }
            .sorted { $0.appName < $1.appName }
    }

    // MARK: - Filter factory

    /// Creates an SCContentFilter capturing only the specified window (not its display).
    ///
    /// Uses desktopIndependentWindow — per-window filter, captures exactly one window
    /// regardless of display layout. Correct for the window-picker UX (SCK-02).
    func filter(for windowInfo: WindowInfo) -> SCContentFilter {
        SCContentFilter(desktopIndependentWindow: windowInfo.scWindow)
    }

    // MARK: - Resolution helper

    /// Returns the pixel dimensions for an SCContentFilter, accounting for display scale.
    ///
    /// SCStreamConfiguration.width/height must be set in pixels, not logical points.
    /// SCWindow.frame is in logical screen coordinates — multiply by screen scale factor.
    func pixelSize(for windowInfo: WindowInfo) -> (width: Int, height: Int) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let width = max(1, Int(windowInfo.frame.width * scale))
        let height = max(1, Int(windowInfo.frame.height * scale))
        return (width, height)
    }
}
