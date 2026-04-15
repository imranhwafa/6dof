import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var mainWindow: NSWindow?

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

        // Permission flow is triggered AFTER window is visible — see PermissionGateway (Plan 02)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
