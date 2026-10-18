import AppKit
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let shortcut = GlobalShortcut()
    private let menuBar = MenuBarController()
    private let popover = PopoverController()
    private let state = TranslationState()
    private let logger = Logger(subsystem: "dev.eli.Pop", category: "App")
    private var task: Task<Void, Never>?
    private var requestID = UUID()
    private var configurationTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var configDate: Date?
    private var configurationIssue: String?
    private var lastSelection: TextSelection?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // A second launch must not register a second hot key or consume API requests.
        if NSRunningApplication.runningApplications(withBundleIdentifier: "dev.eli.Pop").contains(where: {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }) {
            NSApp.terminate(nil)
            return
        }
        menuBar.start()
        shortcut.onPress = { [weak self] in self?.trigger() }
        popover.onClose = { [weak self] in self?.cancel() }
        do { try Configuration.prepare() } catch {
            configurationIssue = "Cannot create config.toml. Check file permissions."
            logger.error("Cannot prepare configuration")
        }
        // Keep a known shortcut available even while the user's TOML is incomplete.
        try? shortcut.register(.init(key: "space", modifiers: ["option"]))
        reloadConfiguration()
        configurationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadIfChanged() }
        }
        if !SelectionReader.isTrusted { SelectionReader.requestPermission() }
        SelectionReader.prepareBrowser(NSWorkspace.shared.frontmostApplication)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                SelectionReader.prepareBrowser(NSWorkspace.shared.frontmostApplication)
            }
        }
        logger.notice("Pop ready; Accessibility=\(SelectionReader.isTrusted)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        task?.cancel()
        configurationTimer?.invalidate()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        shortcut.stop()
        menuBar.stop()
        popover.close()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func reloadIfChanged() {
        let date = try? Configuration.fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if date != configDate { reloadConfiguration() }
    }

    private func reloadConfiguration() {
        configDate = try? Configuration.fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        do {
            let configuration = try Configuration.load()
            try shortcut.register(configuration.shortcut)
            configurationIssue = nil
        } catch {
            configurationIssue = error.localizedDescription
            logger.error("Configuration could not be applied; previous shortcut retained")
        }
    }

    private func trigger() {
        logger.notice("Translation shortcut received")
        if popover.isShown {
            popover.close()
            cancel()
            return
        }
        // Ignore key repeat while waiting for the browser's selection to settle.
        guard task == nil else { return }
        start(selection: nil)
    }

    private func start(selection: TextSelection?) {
        cancel()
        let id = UUID()
        requestID = id
        state.reset()
        if selection == nil { lastSelection = nil }
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.requestID == id { self.task = nil } }
            do {
                let selected: TextSelection
                if let selection { selected = selection }
                else {
                    guard let result = try await SelectionReader.read() else { return }
                    selected = result
                }
                self.lastSelection = selected
                self.show(bounds: selected.bounds)
                self.reloadConfiguration()
                if let issue = self.configurationIssue { throw PopError.message(issue) }
                let configuration = try Configuration.load()
                try Task.checkCancellation()
                guard selected.text.count <= TranslationClient.selectionLimit else {
                    throw PopError.message("Selection exceeds \(TranslationClient.selectionLimit) characters.")
                }
                try await TranslationClient().translate(selected.text, configuration: configuration) { [weak self] delta in
                    guard let self, self.requestID == id else { return }
                    self.state.text += delta
                }
                guard self.requestID == id else { return }
                self.state.isLoading = false
                self.logger.info("Translation completed")
            } catch {
                guard !Task.isCancelled, self.requestID == id else { return }
                self.state.isLoading = false
                if let error = error as? PopError { self.state.error = error.localizedDescription }
                else if let error = error as? URLError, error.code == .timedOut { self.state.error = "Request timed out." }
                else if error is DecodingError { self.state.error = "Invalid API stream response." }
                else if let error = error as? URLError { self.state.error = "Connection failed (\(error.code.rawValue))." }
                else { self.state.error = "Translation failed." }
                let underlying = error as NSError
                self.logger.error("Translation failed: domain=\(underlying.domain, privacy: .public) code=\(underlying.code)")
            }
        }
    }

    private func show(bounds: CGRect) {
        popover.show(state: state, bounds: bounds, copy: { [weak self] in
            guard let self else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(self.state.text, forType: .string)
        }, configure: {
            NSWorkspace.shared.open(Configuration.fileURL)
        }, retry: { [weak self] in
            guard let self else { return }
            let selection = self.lastSelection
            self.popover.close()
            self.start(selection: selection)
        })
    }

    private func cancel() {
        requestID = UUID()
        task?.cancel()
        task = nil
    }
}
