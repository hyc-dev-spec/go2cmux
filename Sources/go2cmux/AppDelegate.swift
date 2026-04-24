import AppKit
import Carbon
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let cmuxBundleIdentifier = "com.cmuxterm.app"
    private let cmuxWorkspaceServiceName = "New cmux Workspace Here"
    private let serviceRetryLimit = 20
    private let cleanupRetryLimit = 5
    private let logURL = URL(fileURLWithPath: "/tmp/go2cmux.log")
    private let openModeDefaultsKey = "FinderToolbarOpenMode"
    private let commandTemplateDefaultsKey = "CommandTemplate"
    private let defaultCommandTemplate = "cd %PATH%; clear; pwd"

    private var didHandleExternalOpen = false
    private var didInstallMainMenu = false
    private var launchSenderBundleIdentifier: String?
    private var settingsWindowController: SettingsWindowController?

    override init() {
        super.init()
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenApplicationEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenApplication)
        )
    }

    @objc private func handleOpenApplicationEvent(
        _ event: NSAppleEventDescriptor,
        withReplyEvent replyEvent: NSAppleEventDescriptor
    ) {
        launchSenderBundleIdentifier = senderBundleIdentifier(for: event)
        log("open-application sender bundle=\(launchSenderBundleIdentifier ?? "nil")")
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        if launchSenderBundleIdentifier == nil {
            launchSenderBundleIdentifier = currentAppleEventSenderBundleIdentifier()
        }
        log("launch sender bundle=\(launchSenderBundleIdentifier ?? "nil")")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard shouldRunFinderToolbarAction() else {
            showSettingsWindow()
            return
        }

        NSApp.setActivationPolicy(.accessory)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, !self.didHandleExternalOpen else { return }
            do {
                let directory = try self.resolveFinderDirectory()
                self.openInCmux(directory)
            } catch {
                self.showErrorAndQuit(self.userFacingMessage(for: error))
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        handleIncomingURLs(urls)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        handleIncomingURLs(filenames.map { URL(fileURLWithPath: $0) })
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard shouldRunFinderToolbarActionOnReopen() else {
            showSettingsWindow()
            return false
        }

        do {
            let directory = try resolveFinderDirectory()
            let keepSettingsWindow = settingsWindowController?.window?.isVisible == true
            log("reopen mode=toolbar dir=\(directory.path) keepSettingsWindow=\(keepSettingsWindow)")
            openInCmux(directory, terminateWhenDone: !keepSettingsWindow)
            return false
        } catch {
            log("reopen mode=settings reason=\(userFacingMessage(for: error))")
            showSettingsWindow()
            return false
        }
    }

    private func shouldRunFinderToolbarAction() -> Bool {
        let senderBundleIdentifier = launchSenderBundleIdentifier ?? currentAppleEventSenderBundleIdentifier()
        guard senderBundleIdentifier == "com.apple.finder" else {
            log("launch mode=settings reason=sender-not-finder")
            return false
        }

        do {
            if try isCurrentBundleSelectedInFinder() {
                log("launch mode=settings reason=finder-selected-self")
                return false
            }
        } catch {
            log("launch mode=settings reason=selection-check-failed error=\(userFacingMessage(for: error))")
            return false
        }

        log("launch mode=toolbar")
        return true
    }

    private func showSettingsWindow() {
        NSApp.setActivationPolicy(.regular)
        installMainMenuIfNeeded()

        if let controller = settingsWindowController, let window = controller.window {
            controller.showWindow(nil)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = SettingsWindowController(
            cmuxURL: resolvedCmuxAppURL,
            openMode: toolbarOpenMode,
            commandTemplate: commandTemplate,
            openModeChanged: { [weak self] mode in
                self?.toolbarOpenMode = mode
            },
            commandTemplateChanged: { [weak self] commandTemplate in
                self?.commandTemplate = commandTemplate
            },
            addToFinderToolbar: { [weak self] in
                self?.addAppToFinderToolbar()
            }
        )
        settingsWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func shouldRunFinderToolbarActionOnReopen() -> Bool {
        let senderBundleIdentifier = currentAppleEventSenderBundleIdentifier()
        guard senderBundleIdentifier == "com.apple.finder" else {
            log("reopen mode=settings reason=sender-not-finder sender=\(senderBundleIdentifier ?? "nil")")
            return false
        }

        log("reopen mode=toolbar reason=sender-finder")
        return true
    }

    private func isCurrentBundleSelectedInFinder() throws -> Bool {
        let selectedPaths = try resolveFinderSelection()
        let bundlePath = Bundle.main.bundleURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path

        return selectedPaths.contains { path in
            URL(fileURLWithPath: path)
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path == bundlePath
        }
    }

    private func currentAppleEventSenderBundleIdentifier() -> String? {
        guard let appleEvent = NSAppleEventManager.shared().currentAppleEvent else {
            return nil
        }

        return senderBundleIdentifier(for: appleEvent)
    }

    private func senderBundleIdentifier(for appleEvent: NSAppleEventDescriptor) -> String? {
        guard let senderPIDDescriptor = appleEvent.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr)) else {
            return nil
        }

        let senderPID = pid_t(senderPIDDescriptor.int32Value)
        guard senderPID > 0,
              let senderApp = NSRunningApplication(processIdentifier: senderPID) else {
            return nil
        }

        return senderApp.bundleIdentifier
    }

    private func installMainMenuIfNeeded() {
        guard !didInstallMainMenu else { return }

        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "go2cmux"

        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: appName)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        appMenu.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
        didInstallMainMenu = true
    }

    private func addAppToFinderToolbar() {
        do {
            let result = try FinderToolbarInstaller.install(appURL: Bundle.main.bundleURL)
            switch result {
            case .alreadyInstalled:
                showSettingsAlert(
                    message: "go2cmux is already in the Finder toolbar.",
                    informativeText: "If the button is not visible, open a new Finder window or restart Finder."
                )
            case .installed:
                try restartFinder()
                showSettingsAlert(
                    message: "Added go2cmux to the Finder toolbar.",
                    informativeText: "Finder was restarted so the toolbar change can take effect."
                )
            }
        } catch {
            showSettingsAlert(
                message: "Could not add go2cmux to the Finder toolbar.",
                informativeText: userFacingMessage(for: error),
                style: .critical
            )
        }
    }

    private func restartFinder() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Finder"]
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw Go2CmuxError.finderRestartFailed
        }
    }

    private func showSettingsAlert(
        message: String,
        informativeText: String,
        style: NSAlert.Style = .informational
    ) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = message
        alert.informativeText = informativeText
        alert.addButton(withTitle: "OK")
        if let window = settingsWindowController?.window ?? NSApp.keyWindow {
            alert.beginSheetModal(for: window) { _ in }
        } else {
            alert.runModal()
        }
    }

    private func handleIncomingURLs(_ urls: [URL]) {
        didHandleExternalOpen = true

        guard resolvedCmuxAppURL != nil else {
            showErrorAndQuit(Go2CmuxError.cmuxAppNotFound.localizedDescription)
            return
        }

        let normalized = normalizeDirectories(urls)
        guard let directory = normalized.first else {
            showErrorAndQuit("No folder was provided to open.")
            return
        }

        openInCmux(directory)
    }

    private func openInCmux(_ directory: URL, terminateWhenDone: Bool = true) {
        guard resolvedCmuxAppURL != nil else {
            showErrorAndQuit(Go2CmuxError.cmuxAppNotFound.localizedDescription)
            return
        }

        switch toolbarOpenMode {
        case .newWindow:
            openWindowInCmux(directory, terminateWhenDone: terminateWhenDone)
        case .newWorkspace:
            openWorkspaceInCmux(directory, terminateWhenDone: terminateWhenDone)
        }
    }

    private func openWorkspaceInCmux(_ directory: URL, terminateWhenDone: Bool) {
        let wasRunning = isCmuxRunning
        log("open workspace start dir=\(directory.path) running=\(wasRunning)")

        if !wasRunning && isHomeDirectory(directory) {
            launchCmuxOnly(directory: directory, terminateWhenDone: terminateWhenDone)
            return
        }

        if wasRunning {
            performWorkspaceService(
                directory,
                retryCount: 0,
                bootstrapCandidate: nil,
                terminateWhenDone: terminateWhenDone
            )
            return
        }

        launchCmuxThenOpen(directory, terminateWhenDone: terminateWhenDone)
    }

    private func openWindowInCmux(_ directory: URL, terminateWhenDone: Bool) {
        let wasRunning = isCmuxRunning
        log("open window start dir=\(directory.path) running=\(wasRunning)")

        if !wasRunning {
            launchCmuxThenOpenWindow(directory, terminateWhenDone: terminateWhenDone)
            return
        }

        createCmuxWindow(directory, terminateWhenDone: terminateWhenDone)
    }

    private func launchCmuxOnly(directory: URL, terminateWhenDone: Bool) {
        guard let cmuxAppURL = resolvedCmuxAppURL else {
            showErrorAndQuit(Go2CmuxError.cmuxAppNotFound.localizedDescription)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        NSWorkspace.shared.openApplication(at: cmuxAppURL, configuration: configuration) { [weak self] _, error in
            guard let self else { return }

            if let error {
                self.showErrorAndQuit("Failed to launch cmux: \(error.localizedDescription)")
                return
            }

            self.waitForCmuxWindows(retryCount: 0) { result in
                switch result {
                case .success:
                    self.inputCommandInFrontTerminal(directory: directory, retryCount: 0, terminateWhenDone: terminateWhenDone)
                case .failure(let error):
                    self.showErrorAndQuit(self.userFacingMessage(for: error))
                }
            }
        }
    }

    private func launchCmuxThenOpen(_ directory: URL, terminateWhenDone: Bool) {
        guard let cmuxAppURL = resolvedCmuxAppURL else {
            showErrorAndQuit(Go2CmuxError.cmuxAppNotFound.localizedDescription)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        NSWorkspace.shared.openApplication(at: cmuxAppURL, configuration: configuration) { [weak self] _, error in
            guard let self else { return }

            if let error {
                self.showErrorAndQuit("Failed to launch cmux: \(error.localizedDescription)")
                return
            }

            self.waitForCmuxWindows(retryCount: 0) { result in
                switch result {
                case .success:
                    let bootstrapCandidate = self.captureBootstrapCandidate()
                    self.performWorkspaceService(
                        directory,
                        retryCount: 0,
                        bootstrapCandidate: bootstrapCandidate,
                        terminateWhenDone: terminateWhenDone
                    )
                case .failure(let error):
                    self.showErrorAndQuit(self.userFacingMessage(for: error))
                }
            }
        }
    }

    private func launchCmuxThenOpenWindow(_ directory: URL, terminateWhenDone: Bool) {
        guard let cmuxAppURL = resolvedCmuxAppURL else {
            showErrorAndQuit(Go2CmuxError.cmuxAppNotFound.localizedDescription)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        NSWorkspace.shared.openApplication(at: cmuxAppURL, configuration: configuration) { [weak self] _, error in
            guard let self else { return }

            if let error {
                self.showErrorAndQuit("Failed to launch cmux: \(error.localizedDescription)")
                return
            }

            self.waitForCmuxWindows(retryCount: 0) { result in
                switch result {
                case .success:
                    if self.isHomeDirectory(directory) {
                        self.finishAction(terminateWhenDone: terminateWhenDone)
                    } else {
                        self.cdFrontCmuxWindow(directory, retryCount: 0, terminateWhenDone: terminateWhenDone)
                    }
                case .failure(let error):
                    self.showErrorAndQuit(self.userFacingMessage(for: error))
                }
            }
        }
    }

    private func createCmuxWindow(_ directory: URL, terminateWhenDone: Bool) {
        let source = """
        tell application "cmux"
            activate
            set targetWindow to new window
            activate window targetWindow
            return id of targetWindow
        end tell
        """

        do {
            guard let windowID = try scriptString(source, target: .cmux),
                  !windowID.isEmpty else {
                showErrorAndQuit("cmux did not return the new window id.")
                return
            }

            cdCmuxWindow(windowID: windowID, directory: directory, retryCount: 0, terminateWhenDone: terminateWhenDone)
        } catch {
            showErrorAndQuit(userFacingMessage(for: error))
        }
    }

    private func cdFrontCmuxWindow(_ directory: URL, retryCount: Int, terminateWhenDone: Bool) {
        let source = """
        tell application "cmux"
            activate
            return id of front window
        end tell
        """

        do {
            guard let windowID = try scriptString(source, target: .cmux),
                  !windowID.isEmpty else {
                showErrorAndQuit("cmux did not return the front window id.")
                return
            }

            cdCmuxWindow(windowID: windowID, directory: directory, retryCount: retryCount, terminateWhenDone: terminateWhenDone)
        } catch {
            showErrorAndQuit(userFacingMessage(for: error))
        }
    }

    private func cdCmuxWindow(windowID: String, directory: URL, retryCount: Int, terminateWhenDone: Bool) {
        let command = commandForDirectory(directory)
        let source = """
        tell application "cmux"
            set targetWindow to first window whose id is "\(escapeAppleScript(windowID))"
            activate window targetWindow
            set targetTab to selected tab of targetWindow
            set targetTerminal to focused terminal of targetTab
            input text ("\(escapeAppleScript(command))" & linefeed) to targetTerminal
        end tell
        """

        do {
            _ = try executeAppleScript(source, target: .cmux)
            finishAction(terminateWhenDone: terminateWhenDone)
        } catch {
            guard retryCount < serviceRetryLimit else {
                showErrorAndQuit(userFacingMessage(for: error))
                return
            }

            log("window cd retry=\(retryCount) error=\(userFacingMessage(for: error))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.cdCmuxWindow(
                    windowID: windowID,
                    directory: directory,
                    retryCount: retryCount + 1,
                    terminateWhenDone: terminateWhenDone
                )
            }
        }
    }

    private func waitForCmuxWindows(
        retryCount: Int,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let windowCount: Int
        do {
            windowCount = try scriptInt("""
            tell application "cmux"
                return count of windows
            end tell
            """, target: .cmux) ?? 0
        } catch {
            completion(.failure(error))
            return
        }

        if windowCount > 0 {
            log("cmux ready windows=\(windowCount)")
            completion(.success(()))
            return
        }

        guard retryCount < serviceRetryLimit else {
            log("cmux not ready after retries")
            completion(.failure(Go2CmuxError.cmuxStartupTimedOut))
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.waitForCmuxWindows(retryCount: retryCount + 1, completion: completion)
        }
    }

    private func performWorkspaceService(
        _ directory: URL,
        retryCount: Int,
        bootstrapCandidate: BootstrapCandidate?,
        terminateWhenDone: Bool
    ) {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pasteboard.clearContents()
        _ = pasteboard.writeObjects([directory as NSURL])
        pasteboard.setPropertyList(
            [directory.path],
            forType: NSPasteboard.PasteboardType(rawValue: "NSFilenamesPboardType")
        )
        pasteboard.setString(directory.path, forType: NSPasteboard.PasteboardType.string)

        NSUpdateDynamicServices()
        let didPerformService = NSPerformService(cmuxWorkspaceServiceName, pasteboard)
        log("service attempt=\(retryCount) ok=\(didPerformService) dir=\(directory.path)")

        if didPerformService {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                self?.closeBootstrapTabIfNeeded(bootstrapCandidate, retryCount: 0) {
                    self?.inputCommandInFrontTerminal(
                        directory: directory,
                        retryCount: 0,
                        terminateWhenDone: terminateWhenDone
                    )
                }
            }
            return
        }

        guard retryCount < serviceRetryLimit else {
            showErrorAndQuit(Go2CmuxError.cmuxServiceUnavailable.localizedDescription)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.performWorkspaceService(
                directory,
                retryCount: retryCount + 1,
                bootstrapCandidate: bootstrapCandidate,
                terminateWhenDone: terminateWhenDone
            )
        }
    }

    private func finishAction(terminateWhenDone: Bool) {
        guard terminateWhenDone else { return }
        NSApp.terminate(nil)
    }

    private func inputCommandInFrontTerminal(directory: URL, retryCount: Int, terminateWhenDone: Bool) {
        let command = commandForDirectory(directory)
        let source = """
        tell application "cmux"
            activate
            set targetWindow to front window
            set targetTab to selected tab of targetWindow
            set targetTerminal to focused terminal of targetTab
            input text ("\(escapeAppleScript(command))" & linefeed) to targetTerminal
        end tell
        """

        do {
            _ = try executeAppleScript(source, target: .cmux)
            finishAction(terminateWhenDone: terminateWhenDone)
        } catch {
            guard retryCount < serviceRetryLimit else {
                showErrorAndQuit(userFacingMessage(for: error))
                return
            }

            log("front command retry=\(retryCount) error=\(userFacingMessage(for: error))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.inputCommandInFrontTerminal(
                    directory: directory,
                    retryCount: retryCount + 1,
                    terminateWhenDone: terminateWhenDone
                )
            }
        }
    }

    private var isCmuxRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: cmuxBundleIdentifier).isEmpty
    }

    private var toolbarOpenMode: ToolbarOpenMode {
        get {
            let rawValue = UserDefaults.standard.string(forKey: openModeDefaultsKey)
            return rawValue.flatMap(ToolbarOpenMode.init(rawValue:)) ?? .newWorkspace
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: openModeDefaultsKey)
        }
    }

    private var commandTemplate: String {
        get {
            let saved = UserDefaults.standard.string(forKey: commandTemplateDefaultsKey) ?? defaultCommandTemplate
            return saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultCommandTemplate : saved
        }
        set {
            let normalized = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(normalized.isEmpty ? defaultCommandTemplate : normalized, forKey: commandTemplateDefaultsKey)
        }
    }

    private func isHomeDirectory(_ directory: URL) -> Bool {
        directory.resolvingSymlinksInPath().standardizedFileURL.path ==
            FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private var resolvedCmuxAppURL: URL? {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: cmuxBundleIdentifier),
           FileManager.default.fileExists(atPath: appURL.path) {
            return appURL
        }

        let fallbackPaths = [
            "/Applications/cmux.app",
            NSString(string: "~/Applications/cmux.app").expandingTildeInPath
        ]

        for path in fallbackPaths where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }

        return nil
    }

    private func captureBootstrapCandidate() -> BootstrapCandidate? {
        let source = """
        tell application "cmux"
            if (count of windows) is not 1 then return ""
            set targetWindow to front window
            if (count of tabs of targetWindow) is not 1 then return ""
            set targetTab to selected tab of targetWindow
            if (name of targetTab) is not "~" then return ""
            return (id of targetWindow) & linefeed & (id of targetTab)
        end tell
        """

        guard let raw = try? scriptString(source, target: .cmux) else {
            log("bootstrap capture: none")
            return nil
        }

        let parts = raw
            .split(whereSeparator: \.isNewline)
            .map(String.init)

        guard parts.count == 2 else {
            log("bootstrap capture: none")
            return nil
        }

        let candidate = BootstrapCandidate(windowID: parts[0], tabID: parts[1])
        log("bootstrap capture window=\(candidate.windowID) tab=\(candidate.tabID)")
        return candidate
    }

    private func closeBootstrapTabIfNeeded(
        _ candidate: BootstrapCandidate?,
        retryCount: Int,
        completion: @escaping () -> Void
    ) {
        guard let candidate else {
            completion()
            return
        }

        let source = """
        tell application "cmux"
            try
                set targetWindow to first window whose id is "\(escapeAppleScript(candidate.windowID))"
                if (count of tabs of targetWindow) is less than or equal to 1 then return "skip"
                set staleTab to first tab of targetWindow whose id is "\(escapeAppleScript(candidate.tabID))"
                set currentTab to selected tab of targetWindow
                if (id of currentTab) is not "\(escapeAppleScript(candidate.tabID))" then
                    close tab staleTab
                    return "closed"
                end if
                return "waiting"
            on error
                return "skip"
            end try
        end tell
        """

        let result = (try? scriptString(source, target: .cmux)) ?? "skip"
        log("bootstrap cleanup result=\(result)")

        guard result == "waiting", retryCount < cleanupRetryLimit else {
            completion()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.closeBootstrapTabIfNeeded(
                candidate,
                retryCount: retryCount + 1,
                completion: completion
            )
        }
    }

    private func resolveFinderDirectory() throws -> URL {
        let source = """
        tell application "Finder"
            if (count of Finder windows) is 0 then
                return POSIX path of (desktop as alias)
            else
                return POSIX path of ((target of front window) as alias)
            end if
        end tell
        """

        guard let path = try scriptString(source, target: .finder),
              !path.isEmpty else {
            throw Go2CmuxError.finderReturnedEmptyDirectory
        }

        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func resolveFinderSelection() throws -> [String] {
        let source = """
        tell application "Finder"
            set selectedItems to selection
            set output to ""
            repeat with selectedItem in selectedItems
                set output to output & POSIX path of (selectedItem as alias) & linefeed
            end repeat
            return output
        end tell
        """

        guard let raw = try scriptString(source, target: .finder),
              !raw.isEmpty else {
            return []
        }

        return raw
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    private func normalizeDirectories(_ urls: [URL]) -> [URL] {
        urls.compactMap { url in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                return nil
            }
            return isDirectory.boolValue ? url : url.deletingLastPathComponent()
        }
    }

    private func scriptString(_ source: String, target: AutomationTarget) throws -> String? {
        let result = try executeAppleScript(source, target: target)
        return result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func scriptInt(_ source: String, target: AutomationTarget) throws -> Int? {
        let result = try executeAppleScript(source, target: target)
        return result.int32Value == 0 && result.stringValue == nil ? nil : Int(result.int32Value)
    }

    private func executeAppleScript(
        _ source: String,
        target: AutomationTarget
    ) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else {
            throw Go2CmuxError.failedToCreateAppleScript(target: target)
        }

        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = (errorInfo[NSAppleScript.errorMessage] as? String)
                ?? errorInfo.description
            let code = errorInfo[NSAppleScript.errorNumber] as? Int
            log("applescript error target=\(target.displayName) code=\(code.map(String.init) ?? "nil") message=\(message)")
            throw Go2CmuxError.appleScriptFailed(target: target, code: code, message: message)
        }

        return result
    }

    private func userFacingMessage(for error: Error) -> String {
        if let go2CmuxError = error as? Go2CmuxError {
            return go2CmuxError.localizedDescription
        }

        return error.localizedDescription
    }

    private func escapeAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func commandForDirectory(_ directory: URL) -> String {
        commandTemplate.replacingOccurrences(of: "%PATH%", with: shellQuoted(directory.path))
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func log(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        let data = Data(line.utf8)

        if FileManager.default.fileExists(atPath: logURL.path) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        } else {
            try? data.write(to: logURL)
        }
    }

    private func showErrorAndQuit(_ message: String) {
        log("error: \(message)")

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "go2cmux"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        NSApp.terminate(nil)
    }
}

private final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private static let defaultCommandTemplate = "cd %PATH%; clear; pwd"
    private static let backgroundColor = NSColor(
        calibratedRed: 0xEC / 255.0,
        green: 0xEC / 255.0,
        blue: 0xEC / 255.0,
        alpha: 1
    )

    private let openModeChanged: (ToolbarOpenMode) -> Void
    private let commandTemplateChanged: (String) -> Void
    private let addToFinderToolbar: () -> Void
    private var commandField: NSTextField?

    init(
        cmuxURL: URL?,
        openMode: ToolbarOpenMode,
        commandTemplate: String,
        openModeChanged: @escaping (ToolbarOpenMode) -> Void,
        commandTemplateChanged: @escaping (String) -> Void,
        addToFinderToolbar: @escaping () -> Void
    ) {
        self.openModeChanged = openModeChanged
        self.commandTemplateChanged = commandTemplateChanged
        self.addToFinderToolbar = addToFinderToolbar

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 345, height: 330),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "go2cmux"
        window.backgroundColor = Self.backgroundColor
        window.center()

        super.init(window: window)
        window.delegate = self
        window.contentView = makeContentView(
            cmuxURL: cmuxURL,
            openMode: openMode,
            commandTemplate: commandTemplate
        )
    }

    required init?(coder: NSCoder) {
        nil
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    private func makeContentView(
        cmuxURL: URL?,
        openMode: ToolbarOpenMode,
        commandTemplate: String
    ) -> NSView {
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 345, height: 330))
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = Self.backgroundColor.cgColor

        let cmuxLabel = label("cmux application to use:", frame: NSRect(x: 20, y: 282, width: 305, height: 22))
        contentView.addSubview(cmuxLabel)

        let cmuxPopup = displayPopupButton(
            item: cmuxURL?.path ?? "cmux.app was not found",
            frame: NSRect(x: 20, y: 250, width: 305, height: 26)
        )
        contentView.addSubview(cmuxPopup)

        let actionLabel = label("Open terminal in:", frame: NSRect(x: 20, y: 214, width: 305, height: 22))
        contentView.addSubview(actionLabel)

        let actionPopup = popupButton(
            items: ToolbarOpenMode.allCases.map(\.title),
            selectedItem: openMode.title,
            frame: NSRect(x: 20, y: 184, width: 305, height: 26)
        )
        contentView.addSubview(actionPopup)

        let commandLabel = label("Command to execute in cmux:", frame: NSRect(x: 20, y: 148, width: 305, height: 22))
        contentView.addSubview(commandLabel)

        let commandField = editableField(commandTemplate, frame: NSRect(x: 20, y: 118, width: 253, height: 26))
        commandField.delegate = self
        contentView.addSubview(commandField)
        self.commandField = commandField

        let resetButton = NSButton(frame: NSRect(x: 279, y: 118, width: 46, height: 26))
        resetButton.title = "Reset"
        resetButton.bezelStyle = .rounded
        resetButton.font = .systemFont(ofSize: 12)
        resetButton.target = self
        resetButton.action = #selector(resetCommandTemplate)
        contentView.addSubview(resetButton)

        let commandHint = wrappingLabel(
            "%PATH% will be replaced with a path to current Finder window.",
            frame: NSRect(x: 20, y: 98, width: 305, height: 14),
            fontSize: 9
        )
        contentView.addSubview(commandHint)

        let button = NSButton(frame: NSRect(x: 20, y: 58, width: 305, height: 26))
        button.title = "Add go2cmux button to Finder Toolbar"
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        button.keyEquivalentModifierMask = []
        button.target = self
        button.action = #selector(addButtonToFinderToolbar)
        contentView.addSubview(button)

        let hint = wrappingLabel(
            "Hold `command`, then drag go2cmux.app to the Finder toolbar. Clicking that toolbar button opens the current Finder folder in cmux.",
            frame: NSRect(x: 20, y: 24, width: 305, height: 28),
            fontSize: 9
        )
        contentView.addSubview(hint)

        return contentView
    }

    private func label(_ text: String, frame: NSRect) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.frame = frame
        field.font = .systemFont(ofSize: 14)
        return field
    }

    private func wrappingLabel(_ text: String, frame: NSRect, fontSize: CGFloat = 12) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.frame = frame
        field.font = .systemFont(ofSize: fontSize)
        field.textColor = .secondaryLabelColor
        return field
    }

    private func readOnlyField(_ text: String, frame: NSRect) -> NSTextField {
        let field = NSTextField(frame: frame)
        field.stringValue = text
        field.font = .systemFont(ofSize: 14)
        field.isEditable = false
        field.isSelectable = true
        styleRoundedTextField(field, backgroundColor: .controlBackgroundColor)
        return field
    }

    private func editableField(_ text: String, frame: NSRect) -> NSTextField {
        let field = NSTextField(frame: frame)
        field.stringValue = text
        field.font = .systemFont(ofSize: 14)
        field.isEditable = true
        field.isSelectable = true
        styleRoundedTextField(field, backgroundColor: .textBackgroundColor)
        return field
    }

    private func styleRoundedTextField(_ field: NSTextField, backgroundColor: NSColor) {
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.backgroundColor = backgroundColor
        field.focusRingType = .default
        field.wantsLayer = false
    }

    private func popupButton(items: [String], selectedItem: String, frame: NSRect) -> NSPopUpButton {
        let button = NSPopUpButton(frame: frame, pullsDown: false)
        button.cell = TighterPopUpButtonCell(textCell: "", pullsDown: false)
        button.addItems(withTitles: items)
        button.selectItem(withTitle: selectedItem)
        button.font = .systemFont(ofSize: 14)
        button.target = self
        button.action = #selector(openModePopupChanged(_:))
        return button
    }

    private func displayPopupButton(item: String, frame: NSRect) -> NSPopUpButton {
        let button = NSPopUpButton(frame: frame, pullsDown: false)
        button.cell = TighterPopUpButtonCell(textCell: "", pullsDown: false)
        button.addItem(withTitle: item)
        button.selectItem(at: 0)
        button.font = .systemFont(ofSize: 14)
        return button
    }

    @objc private func openModePopupChanged(_ sender: NSPopUpButton) {
        guard let title = sender.selectedItem?.title,
              let mode = ToolbarOpenMode(title: title) else {
            return
        }
        openModeChanged(mode)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              field === commandField else {
            return
        }
        commandTemplateChanged(field.stringValue)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              field === commandField else {
            return
        }

        let normalized = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            field.stringValue = Self.defaultCommandTemplate
            commandTemplateChanged(Self.defaultCommandTemplate)
        }
    }

    @objc private func resetCommandTemplate() {
        commandField?.stringValue = Self.defaultCommandTemplate
        commandTemplateChanged(Self.defaultCommandTemplate)
    }

    @objc private func addButtonToFinderToolbar() {
        addToFinderToolbar()
    }
}

private final class TighterPopUpButtonCell: NSPopUpButtonCell {
    private let titleOffset: CGFloat = -8

    override func titleRect(forBounds cellFrame: NSRect) -> NSRect {
        var rect = super.titleRect(forBounds: cellFrame)
        rect.origin.x += titleOffset
        rect.size.width -= titleOffset
        return rect
    }
}

private enum ToolbarOpenMode: String, CaseIterable {
    case newWindow
    case newWorkspace

    init?(title: String) {
        guard let mode = Self.allCases.first(where: { $0.title == title }) else {
            return nil
        }
        self = mode
    }

    var title: String {
        switch self {
        case .newWindow:
            return "New cmux Window"
        case .newWorkspace:
            return "New cmux Workspace"
        }
    }
}

private enum FinderToolbarInstallResult {
    case installed
    case alreadyInstalled
}

private enum FinderToolbarInstaller {
    private static let configurationKey = "NSToolbar Configuration Browser"
    private static let itemIdentifiersKey = "TB Item Identifiers"
    private static let defaultItemIdentifiersKey = "TB Default Item Identifiers"
    private static let itemPlistsKey = "TB Item Plists"
    private static let locationItemIdentifier = "com.apple.finder.loc "
    private static let searchItemIdentifier = "com.apple.finder.SRCH"

    static func install(appURL: URL) throws -> FinderToolbarInstallResult {
        let fileManager = FileManager.default
        let preferencesURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.apple.finder.plist")
        let appURL = appURL.resolvingSymlinksInPath().standardizedFileURL
        let appPath = appURL.path

        var root = try readFinderPreferences(at: preferencesURL)
        var configuration = root[configurationKey] as? [String: Any] ?? [:]
        var identifiers = configuration[itemIdentifiersKey] as? [String]
            ?? configuration[defaultItemIdentifiersKey] as? [String]
            ?? defaultToolbarIdentifiers()
        var itemPlists = configuration[itemPlistsKey] as? [String: Any] ?? [:]

        if toolbarAlreadyContainsApp(
            appPath: appPath,
            identifiers: identifiers,
            itemPlists: itemPlists
        ) {
            return .alreadyInstalled
        }

        try backupFinderPreferencesIfNeeded(at: preferencesURL)

        let insertIndex = identifiers.lastIndex(of: searchItemIdentifier) ?? identifiers.count
        identifiers.insert(locationItemIdentifier, at: insertIndex)
        itemPlists = itemPlistsByShifting(itemPlists, from: insertIndex)
        itemPlists[String(insertIndex)] = toolbarItemPlist(for: appURL)

        configuration[itemIdentifiersKey] = identifiers
        configuration[defaultItemIdentifiersKey] = configuration[defaultItemIdentifiersKey] ?? defaultToolbarIdentifiers()
        configuration[itemPlistsKey] = itemPlists
        configuration["TB Display Mode"] = configuration["TB Display Mode"] ?? 1
        configuration["TB Icon Size Mode"] = configuration["TB Icon Size Mode"] ?? 1
        configuration["TB Is Shown"] = 1
        configuration["TB Size Mode"] = configuration["TB Size Mode"] ?? 1
        root[configurationKey] = configuration

        try writeFinderPreferences(root, to: preferencesURL)
        return .installed
    }

    private static func readFinderPreferences(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return [:]
        }

        let data = try Data(contentsOf: url)
        guard let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [.mutableContainersAndLeaves],
            format: nil
        ) as? [String: Any] else {
            throw Go2CmuxError.finderToolbarInstallFailed("Finder preferences are not a property-list dictionary.")
        }
        return plist
    }

    private static func writeFinderPreferences(_ plist: [String: Any], to url: URL) throws {
        guard let finderDefaults = UserDefaults(suiteName: "com.apple.finder") else {
            throw Go2CmuxError.finderToolbarInstallFailed("Could not open Finder preferences.")
        }

        finderDefaults.setPersistentDomain(plist, forName: "com.apple.finder")
        guard finderDefaults.synchronize() else {
            throw Go2CmuxError.finderToolbarInstallFailed("Could not save Finder preferences.")
        }
    }

    private static func backupFinderPreferencesIfNeeded(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        let backupURL = url.deletingLastPathComponent()
            .appendingPathComponent("com.apple.finder.plist.go2cmux-backup-\(formatter.string(from: Date()))")
        try FileManager.default.copyItem(at: url, to: backupURL)
    }

    private static func toolbarAlreadyContainsApp(
        appPath: String,
        identifiers: [String],
        itemPlists: [String: Any]
    ) -> Bool {
        for (index, identifier) in identifiers.enumerated() where identifier == locationItemIdentifier {
            guard let itemPlist = itemPlists[String(index)] as? [String: Any],
                  let itemPath = toolbarItemPath(itemPlist) else {
                continue
            }

            if itemPath == appPath {
                return true
            }
        }
        return false
    }

    private static func toolbarItemPath(_ itemPlist: [String: Any]) -> String? {
        guard let rawURLString = itemPlist["_CFURLString"] as? String else {
            return nil
        }

        let url: URL?
        if rawURLString.hasPrefix("/") {
            url = URL(fileURLWithPath: rawURLString)
        } else {
            url = URL(string: rawURLString)
        }

        return url?
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    private static func itemPlistsByShifting(
        _ itemPlists: [String: Any],
        from insertIndex: Int
    ) -> [String: Any] {
        var shifted: [String: Any] = [:]

        for (key, value) in itemPlists {
            guard let index = Int(key), index >= insertIndex else {
                shifted[key] = value
                continue
            }
            shifted[String(index + 1)] = value
        }

        return shifted
    }

    private static func toolbarItemPlist(for appURL: URL) -> [String: Any] {
        [
            "_CFURLString": appURL.absoluteString,
            "_CFURLStringType": 15
        ]
    }

    private static func defaultToolbarIdentifiers() -> [String] {
        [
            "com.apple.finder.BACK",
            "com.apple.finder.SWCH",
            "NSToolbarSpaceItem",
            "com.apple.finder.ARNG",
            "NSToolbarSpaceItem",
            "com.apple.finder.SHAR",
            "com.apple.finder.LABL",
            "com.apple.finder.ACTN",
            "NSToolbarSpaceItem",
            "com.apple.finder.SRCH"
        ]
    }
}

private struct BootstrapCandidate {
    let windowID: String
    let tabID: String
}

private enum AutomationTarget {
    case finder
    case cmux

    var displayName: String {
        switch self {
        case .finder:
            return "Finder"
        case .cmux:
            return "cmux"
        }
    }
}

private enum Go2CmuxError: LocalizedError {
    case cmuxAppNotFound
    case finderReturnedEmptyDirectory
    case failedToCreateAppleScript(target: AutomationTarget)
    case appleScriptFailed(target: AutomationTarget, code: Int?, message: String)
    case cmuxStartupTimedOut
    case cmuxServiceUnavailable
    case finderRestartFailed
    case finderToolbarInstallFailed(String)

    var errorDescription: String? {
        switch self {
        case .cmuxAppNotFound:
            return "Could not find cmux.app. Make sure the released version of cmux is installed in /Applications or ~/Applications."
        case .finderReturnedEmptyDirectory:
            return "Finder did not return a valid folder."
        case .failedToCreateAppleScript(let target):
            return "Could not create the AppleScript used to access \(target.displayName)."
        case .appleScriptFailed(let target, let code, let message):
            if code == -1743 {
                return "Allow go2cmux to control \(target.displayName) in System Settings > Privacy & Security > Automation, then try again."
            }

            if code == -1712 {
                return "\(target.displayName) timed out. Please try again."
            }

            if let code {
                return "Could not access \(target.displayName) (error \(code)): \(message)"
            }

            return "Could not access \(target.displayName): \(message)"
        case .cmuxStartupTimedOut:
            return "cmux did not present a window in time. If this is the first launch, make sure go2cmux is allowed to control cmux."
        case .cmuxServiceUnavailable:
            return "Failed to invoke the cmux Finder Service. Make sure cmux is installed correctly and go2cmux is allowed to control cmux in System Settings > Privacy & Security > Automation."
        case .finderRestartFailed:
            return "Updated Finder toolbar preferences, but could not restart Finder. Restart Finder manually to apply the change."
        case .finderToolbarInstallFailed(let message):
            return message
        }
    }
}
