import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let cmuxBundleIdentifier = "com.cmuxterm.app"
    private let cmuxWorkspaceServiceName = "New cmux Workspace Here"
    private let serviceRetryLimit = 20
    private let cleanupRetryLimit = 5
    private let logURL = URL(fileURLWithPath: "/tmp/go2cmux.log")

    private var didHandleExternalOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
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

    private func openInCmux(_ directory: URL) {
        guard resolvedCmuxAppURL != nil else {
            showErrorAndQuit(Go2CmuxError.cmuxAppNotFound.localizedDescription)
            return
        }

        let wasRunning = isCmuxRunning
        log("open start dir=\(directory.path) running=\(wasRunning)")

        if !wasRunning && isHomeDirectory(directory) {
            launchCmuxOnly()
            return
        }

        if wasRunning {
            performWorkspaceService(
                directory,
                retryCount: 0,
                bootstrapCandidate: nil
            )
            return
        }

        launchCmuxThenOpen(directory)
    }

    private func launchCmuxOnly() {
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

            NSApp.terminate(nil)
        }
    }

    private func launchCmuxThenOpen(_ directory: URL) {
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
                        bootstrapCandidate: bootstrapCandidate
                    )
                case .failure(let error):
                    self.showErrorAndQuit(self.userFacingMessage(for: error))
                }
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
        bootstrapCandidate: BootstrapCandidate?
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
                    NSApp.terminate(nil)
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
                bootstrapCandidate: bootstrapCandidate
            )
        }
    }

    private var isCmuxRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: cmuxBundleIdentifier).isEmpty
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
        }
    }
}
