import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    // NSApplication holds its delegate weakly, and Swift may release a local
    // after its last use; the delegate owns the status item and popover.
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
