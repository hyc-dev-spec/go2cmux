import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let cmuxAppURL = URL(fileURLWithPath: "/Applications/cmux.app", isDirectory: true)
    private let cmuxBundleIdentifier = "com.cmuxterm.app"
    private let cmuxWorkspaceServiceName = "New cmux Workspace Here"
    private let serviceRetryLimit = 20
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
                self.showErrorAndQuit("无法读取 Finder 当前文件夹：\(error.localizedDescription)")
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

        guard FileManager.default.fileExists(atPath: cmuxAppURL.path) else {
            showErrorAndQuit("未找到 \(cmuxAppURL.path)")
            return
        }

        let normalized = normalizeDirectories(urls)
        guard let directory = normalized.first else {
            showErrorAndQuit("没有收到可打开的文件夹。")
            return
        }

        openInCmux(directory)
    }

    private func openInCmux(_ directory: URL) {
        guard FileManager.default.fileExists(atPath: cmuxAppURL.path) else {
            showErrorAndQuit("未找到 \(cmuxAppURL.path)")
            return
        }

        let wasRunning = isCmuxRunning
        log("open start dir=\(directory.path) running=\(wasRunning)")

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

    private func launchCmuxThenOpen(_ directory: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        NSWorkspace.shared.openApplication(at: cmuxAppURL, configuration: configuration) { [weak self] _, error in
            guard let self else { return }

            if let error {
                self.showErrorAndQuit("启动 cmux 失败：\(error.localizedDescription)")
                return
            }

            self.waitForCmuxWindows(retryCount: 0) { ready in
                guard ready else {
                    self.showErrorAndQuit("cmux 启动后没有及时出现窗口。")
                    return
                }

                let bootstrapCandidate = self.captureBootstrapCandidate()
                self.performWorkspaceService(
                    directory,
                    retryCount: 0,
                    bootstrapCandidate: bootstrapCandidate
                )
            }
        }
    }

    private func waitForCmuxWindows(retryCount: Int, completion: @escaping (Bool) -> Void) {
        let windowCount = scriptInt("""
        tell application "cmux"
            return count of windows
        end tell
        """) ?? 0

        if windowCount > 0 {
            log("cmux ready windows=\(windowCount)")
            completion(true)
            return
        }

        guard retryCount < serviceRetryLimit else {
            log("cmux not ready after retries")
            completion(false)
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
                self?.closeBootstrapTabIfNeeded(bootstrapCandidate)
                NSApp.terminate(nil)
            }
            return
        }

        guard retryCount < serviceRetryLimit else {
            showErrorAndQuit("调用 cmux Finder Service 失败。")
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

        guard let raw = scriptString(source) else {
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

    private func closeBootstrapTabIfNeeded(_ candidate: BootstrapCandidate?) {
        guard let candidate else { return }

        let source = """
        tell application "cmux"
            try
                set targetWindow to first window whose id is "\(escapeAppleScript(candidate.windowID))"
                if (count of tabs of targetWindow) is less than or equal to 1 then return "skip"
                set staleTab to first tab of targetWindow whose id is "\(escapeAppleScript(candidate.tabID))"
                set currentTab to selected tab of targetWindow
                if (name of staleTab) is "~" and (name of currentTab) is not "~" then
                    close tab staleTab
                    return "closed"
                end if
                return "skip"
            on error
                return "skip"
            end try
        end tell
        """

        let result = scriptString(source) ?? "skip"
        log("bootstrap cleanup result=\(result)")
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

        guard let script = NSAppleScript(source: source) else {
            throw NSError(domain: "go2cmux", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "无法创建 Finder AppleScript。"
            ])
        }

        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = (errorInfo[NSAppleScript.errorMessage] as? String)
                ?? errorInfo.description
            throw NSError(domain: "go2cmux", code: 2, userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }

        guard let path = result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            throw NSError(domain: "go2cmux", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Finder 没有返回有效目录。"
            ])
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

    private func scriptString(_ source: String) -> String? {
        do {
            let result = try executeAppleScript(source)
            return result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            log("script string failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func scriptInt(_ source: String) -> Int? {
        do {
            let result = try executeAppleScript(source)
            return result.int32Value == 0 && result.stringValue == nil ? nil : Int(result.int32Value)
        } catch {
            log("script int failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func executeAppleScript(_ source: String) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else {
            throw NSError(domain: "go2cmux", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "无法创建 AppleScript。"
            ])
        }

        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = (errorInfo[NSAppleScript.errorMessage] as? String)
                ?? errorInfo.description
            throw NSError(domain: "go2cmux", code: 11, userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }

        return result
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
                try? handle.seekToEnd()
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
        alert.addButton(withTitle: "好")
        alert.runModal()
        NSApp.terminate(nil)
    }
}

private struct BootstrapCandidate {
    let windowID: String
    let tabID: String
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
