import AppKit
import OSLog
@preconcurrency import ApplicationServices

struct TextSelection {
    let text: String
    let bounds: CGRect
}

@MainActor
enum SelectionReader {
    private static let logger = Logger(subsystem: "dev.eli.Pop", category: "Selection")
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestPermission() {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    private static let chromiumBundles: Set<String> = [
        "com.google.Chrome", "com.microsoft.edgemac", "company.thebrowser.Browser",
        "company.thebrowser.dia", "com.brave.Browser", "com.openai.codex"
    ]

    static func prepareBrowser(_ application: NSRunningApplication?) {
        guard isTrusted, let application,
              chromiumBundles.contains(application.bundleIdentifier ?? "") else { return }
        let app = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.1)
        if attribute(app, "AXManualAccessibility") as? Bool != true {
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
    }

    static func read(application requestedApplication: NSRunningApplication? = nil) async throws -> TextSelection? {
        guard isTrusted else {
            logger.notice("Selection blocked: Accessibility permission is not active")
            requestPermission()
            return nil
        }
        guard let application = requestedApplication ?? NSWorkspace.shared.frontmostApplication,
              application.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        prepareBrowser(application)
        let browser = chromiumBundles.contains(application.bundleIdentifier ?? "") || application.bundleIdentifier == "com.apple.Safari"
        let delays = browser ? [0, 80, 160, 260] : [0]
        for (attempt, delay) in delays.enumerated() {
            try Task.checkCancellation()
            if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
            if requestedApplication == nil,
               NSWorkspace.shared.frontmostApplication?.processIdentifier != application.processIdentifier { return nil }
            if let selection = scan(application: application, budget: browser ? 0.35 : 1) {
                logger.notice("Selection ready after \(attempt + 1) attempt(s)")
                return selection
            }
        }
        return nil
    }

    private static func scan(application: NSRunningApplication, budget: TimeInterval) -> TextSelection? {
        logger.notice("Reading selection from \(application.bundleIdentifier ?? "unknown", privacy: .public)")
        let app = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.1)
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        var focused = elementAttribute(app, kAXFocusedUIElementAttribute)
        if focused == nil, let systemFocused = elementAttribute(system, kAXFocusedUIElementAttribute) {
            var pid: pid_t = 0
            if AXUIElementGetPid(systemFocused, &pid) == .success, pid == application.processIdentifier { focused = systemFocused }
        }
        var queue: [AXUIElement] = []
        var webScope: AXUIElement?
        if let focused {
            queue.append(focused)
            var element: AXUIElement? = focused
            for _ in 0..<8 {
                guard let current = element else { break }
                if let selection = selection(in: current) { return selection }
                if attribute(current, kAXRoleAttribute) as? String == "AXWebArea" {
                    webScope = current
                    break
                }
                element = elementAttribute(current, kAXParentAttribute)
            }
        }
        if let webScope { queue = [webScope] }
        else if let window = elementAttribute(app, kAXFocusedWindowAttribute) ?? elementAttribute(app, kAXMainWindowAttribute) {
            queue.append(window)
        }
        var index = 0
        var visited = Set<AXUIElement>()
        let deadline = Date().addingTimeInterval(budget)
        while index < queue.count && index < 1200 && Date() < deadline {
            let current = queue[index]
            index += 1
            guard visited.insert(current).inserted else { continue }
            if attribute(current, kAXRoleAttribute) as? String == "AXWebArea" {
                if let webScope {
                    guard current == webScope else { continue }
                } else { webScope = current }
            }
            if let selection = selection(in: current) { return selection }
            let children = attribute(current, kAXChildrenAttribute) as? [AXUIElement] ?? []
            let contents = attribute(current, "AXContents") as? [AXUIElement] ?? []
            queue.append(contentsOf: (contents + children).prefix(max(0, 1200 - queue.count)))
        }
        logger.notice("Selection scan ended: elements=\(index)")
        // Never copy an unverified selection: some editors copy the entire line at an empty caret.
        // Never substitute the mouse position for text bounds.
        return nil
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func selection(in element: AXUIElement) -> TextSelection? {
        AXUIElementSetMessagingTimeout(element, 0.1)
        if let webSelection = markerSelection(in: element) { return webSelection }
        guard let rangeValue = attribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeDowncast(rangeValue, to: AXValue.self), .cfRange, &range), range.length > 0 else { return nil }
        logger.notice("Nonempty selected range: location=\(range.location) length=\(range.length)")
        var text = attribute(element, kAXSelectedTextAttribute) as? String
        if text?.isEmpty != false {
            var value: CFTypeRef?
            let result = AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &value)
            if result == .success { text = value as? String }
        }
        if text?.isEmpty != false,
           let fullText = attribute(element, kAXValueAttribute) as? String {
            let value = fullText as NSString
            if range.location >= 0, range.length <= value.length,
               range.location <= value.length - range.length {
                text = value.substring(with: NSRange(location: range.location, length: range.length))
            }
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.notice("Nonempty range but text attributes are unavailable")
            return nil
        }
        if let reconstructed = markerSelection(in: element, range: range, expectedText: text) { return reconstructed }
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        func appKitRect(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
        }
        var textFrame: CGRect?
        if let positionValue = attribute(element, kAXPositionAttribute),
           let sizeValue = attribute(element, kAXSizeAttribute),
           CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() {
            var point = CGPoint.zero
            var size = CGSize.zero
            if AXValueGetValue(unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &point),
               AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size) {
                textFrame = appKitRect(CGRect(origin: point, size: size))
            }
        }
        func clipped(_ rect: CGRect) -> CGRect? {
            var rect = appKitRect(rect)
            if let textFrame { rect = rect.intersection(textFrame) }
            for screen in NSScreen.screens {
                let visible = rect.intersection(screen.visibleFrame)
                if !visible.isNull, visible.width > 0, visible.height > 0 { return visible }
            }
            return nil
        }
        // A selection may start above the visible viewport (for example, Select All
        // in a scrolled editor). Anchor to selected text that is actually visible.
        var anchorRange = CFRange(location: range.location, length: 1)
        if let visibleValue = attribute(element, kAXVisibleCharacterRangeAttribute),
           CFGetTypeID(visibleValue) == AXValueGetTypeID() {
            var visibleRange = CFRange()
            if AXValueGetValue(unsafeDowncast(visibleValue, to: AXValue.self), .cfRange, &visibleRange),
               visibleRange.length > 0 {
                let start = max(range.location, visibleRange.location)
                if start < min(range.location + range.length, visibleRange.location + visibleRange.length) {
                    anchorRange.location = start
                }
            }
        }
        var screenRect: CGRect?
        if let rect = bounds(in: element, range: unsafeDowncast(rangeValue, to: AXValue.self)),
           let visible = clipped(rect), visible.height <= 120 { screenRect = visible }
        if screenRect == nil, let glyphValue = AXValueCreate(.cfRange, &anchorRange),
           let rect = bounds(in: element, range: glyphValue) { screenRect = clipped(rect) }
        if screenRect == nil,
           let rect = bounds(in: element, range: unsafeDowncast(rangeValue, to: AXValue.self)),
           let visibleRect = clipped(rect) {
            screenRect = CGRect(x: visibleRect.minX, y: visibleRect.maxY - min(18, visibleRect.height),
                                width: min(visibleRect.width, 12), height: min(18, visibleRect.height))
        }
        guard let screenRect else {
            logger.notice("Selection text read, but selected bounds are outside the visible viewport or unavailable")
            return nil
        }
        logger.notice("Selection resolved: x=\(screenRect.minX) y=\(screenRect.minY) w=\(screenRect.width) h=\(screenRect.height)")
        return TextSelection(text: text, bounds: screenRect)
    }

    // Chromium and WebKit expose document selections as opaque text markers,
    // rather than the CFRange used by NSTextView.
    private static func parameter(_ element: AXUIElement, _ name: String, _ value: CFTypeRef) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, value, &result) == .success else { return nil }
        return result
    }

    private static func markerSelection(in element: AXUIElement) -> TextSelection? {
        guard let marker = attribute(element, "AXSelectedTextMarkerRange") else { return nil }
        return selection(in: element, marker: marker)
    }

    private static func markerSelection(in element: AXUIElement, range: CFRange, expectedText: String) -> TextSelection? {
        // Browser CFRange geometry is unreliable. On a web area its offsets are
        // document-relative, so rebuild fresh markers and verify the exact text.
        guard attribute(element, kAXRoleAttribute) as? String == "AXWebArea",
              let start = parameter(element, "AXTextMarkerForIndex", NSNumber(value: range.location)),
              let end = parameter(element, "AXTextMarkerForIndex", NSNumber(value: range.location + range.length)),
              let marker = parameter(element, "AXTextMarkerRangeForUnorderedTextMarkers", [start, end] as CFArray) else { return nil }
        return selection(in: element, marker: marker, expectedText: expectedText)
    }

    private static func selection(in element: AXUIElement, marker: CFTypeRef, expectedText: String? = nil) -> TextSelection? {
        guard let text = parameter(element, "AXStringForTextMarkerRange", marker) as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              expectedText == nil || text == expectedText,
              let boundsValue = parameter(element, "AXBoundsForTextMarkerRange", marker),
              CFGetTypeID(boundsValue) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(unsafeDowncast(boundsValue, to: AXValue.self), .cgRect, &rect),
              rect.width > 0, rect.height > 0, rect.minX.isFinite, rect.minY.isFinite,
              rect.width.isFinite, rect.height.isFinite else { return nil }
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let screenRect = CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
        for screen in NSScreen.screens {
            let visible = screenRect.intersection(screen.visibleFrame)
            guard !visible.isNull, visible.width > 0, visible.height > 0 else { continue }
            let anchor = visible.height <= 120 ? visible : CGRect(
                x: visible.minX, y: visible.maxY - 18, width: visible.width, height: 18)
            logger.notice("Browser selection resolved: characters=\(text.count) x=\(anchor.minX) y=\(anchor.minY)")
            return TextSelection(text: text, bounds: anchor)
        }
        return nil
    }

    private static func bounds(in element: AXUIElement, range: AXValue) -> CGRect? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgRect, &rect),
              rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }
}
