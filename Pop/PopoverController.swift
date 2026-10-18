import AppKit
import SwiftUI
import OSLog

@MainActor
final class PopoverController: NSObject, NSPopoverDelegate {
    private let logger = Logger(subsystem: "dev.eli.Pop", category: "Popover")
    private let popover = NSPopover()
    private let anchor = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
    private var localMonitor: Any?
    private var globalMonitor: Any?
    var onClose: (() -> Void)?
    var isShown: Bool { popover.isShown }

    override init() {
        super.init()
        anchor.isOpaque = false
        anchor.backgroundColor = .clear
        anchor.hasShadow = false
        anchor.level = .popUpMenu
        anchor.ignoresMouseEvents = true
        anchor.hidesOnDeactivate = false
        anchor.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        anchor.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self
    }

    func show(state: TranslationState, bounds: CGRect, copy: @escaping () -> Void,
              configure: @escaping () -> Void, retry: @escaping () -> Void) {
        if popover.isShown { close() }
        let hosting = NSHostingController(rootView: TranslationView(
            state: state, copy: copy, configure: configure, retry: retry,
            dismiss: { [weak self] in self?.close() }, sizeChanged: { [weak self] size in
                Task { @MainActor [weak self] in self?.resize(to: size) }
            }))
        // NSPopover must own window sizing. Automatic NSHostingController resizing
        // changes the window frame without keeping the popover arrow at its anchor.
        hosting.sizingOptions = []
        hosting.view.frame = NSRect(x: 0, y: 0, width: 360, height: 76)
        popover.contentViewController = hosting
        popover.contentSize = NSSize(width: 360, height: 76)
        // Keep the anchor over the real glyph rect. Let NSPopover reposition its body
        // at screen edges while preserving the arrow's attachment to the selected text.
        anchor.setFrame(bounds, display: false)
        anchor.contentView?.frame = NSRect(origin: .zero, size: bounds.size)
        anchor.orderFrontRegardless()
        logger.notice("Requested anchor=\(String(describing: bounds), privacy: .public) window=\(String(describing: self.anchor.frame), privacy: .public) content=\(String(describing: self.anchor.contentView?.frame), privacy: .public)")
        if let view = anchor.contentView {
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
        logger.notice("Popover frame=\(String(describing: self.popover.contentViewController?.view.window?.frame), privacy: .public) positioning=\(String(describing: self.popover.positioningRect), privacy: .public)")
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            let dismissEvent = MainActor.assumeIsolated {
                guard let self else { return false }
                if event.type == .keyDown && event.keyCode == 53 {
                    self.close()
                    return true
                }
                if event.type != .keyDown && event.window != self.popover.contentViewController?.view.window {
                    self.close()
                }
                return false
            }
            return dismissEvent ? nil : event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if event.type != .keyDown || event.keyCode == 53 { self?.close() }
            }
        }
    }

    private func resize(to size: CGSize) {
        guard popover.isShown, let view = anchor.contentView,
              size.width > 0, size.height > 0 else { return }
        let size = NSSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
        guard popover.contentSize != size else { return }
        popover.animates = false
        defer { popover.animates = true }
        popover.contentSize = size
        // Reposition after every streamed height change, including screen-edge flips.
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        logger.notice("Resized popover=\(String(describing: self.popover.contentViewController?.view.window?.frame), privacy: .public) anchor=\(String(describing: self.anchor.frame), privacy: .public)")
    }

    func close() {
        popover.performClose(nil)
        anchor.orderOut(nil)
        removeMonitors()
    }

    func popoverDidClose(_ notification: Notification) {
        anchor.orderOut(nil)
        removeMonitors()
        onClose?()
    }

    private func removeMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }
}
