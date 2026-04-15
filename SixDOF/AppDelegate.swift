import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var mainWindow: NSWindow?
    private var coordinator: AppCoordinator?

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

        // AppCoordinator owns PermissionGateway, WindowPicker, and CaptureManager.
        // start() defers the TCC permission call until after the window is visible.
        let coord = AppCoordinator()
        coordinator = coord
        coord.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
