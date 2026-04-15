import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var mainWindow: NSWindow?
    private let permissionGateway = PermissionGateway()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create minimal window — must be visible before any SCK permission calls
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SixDOF — Capture Foundation"
        window.center()
        window.makeKeyAndOrderFront(nil)
        mainWindow = window

        // Permission must be requested AFTER the window is visible — never at launch
        Task { @MainActor in
            let status = await self.permissionGateway.requestPermission()
            print("[AppDelegate] Screen recording permission: \(status)")
            // CaptureManager start will be gated here in Plan 04
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
