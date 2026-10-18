import AppKit

@MainActor
final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?

    func start() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Self.symbolImage
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.toolTip = "Pop"
            button.setAccessibilityLabel("Pop")
        }
        let menu = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        settings.preferredImageVisibility = .visible
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    func stop() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    @objc private func openSettings() {
        try? Configuration.prepare()
        NSWorkspace.shared.open(Configuration.fileURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private static var symbolImage: NSImage {
        let image = NSImage(systemSymbolName: "bubble.middle.top.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 17 * 0.85, weight: .medium))
            ?? NSImage()
        image.isTemplate = true
        return image
    }
}
