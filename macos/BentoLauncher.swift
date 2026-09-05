import AppKit
import Darwin
import Foundation

private enum LauncherError: LocalizedError {
    case missingResource(String)
    case invalidRepository(String)

    var errorDescription: String? {
        switch self {
        case .missingResource(let name):
            return "Bento.app is missing its \(name) resource. Rebuild the app."
        case .invalidRepository(let path):
            return "Bento.app cannot find scripts/run-vm.sh in \(path). Rebuild the app from the Bento repository."
        }
    }
}

private func alert(
    title: String,
    message: String,
    style: NSAlert.Style = .warning
) {
    NSApp.activate(ignoringOtherApps: true)
    let panel = NSAlert()
    panel.alertStyle = style
    panel.messageText = title
    panel.informativeText = message
    panel.runModal()
}

private func repositoryURL() throws -> URL {
    guard let pathURL = Bundle.main.url(forResource: "repository-path", withExtension: nil) else {
        throw LauncherError.missingResource("repository-path")
    }
    let path = try String(contentsOf: pathURL, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let repository = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    guard FileManager.default.isExecutableFile(
        atPath: repository.appendingPathComponent("scripts/run-vm.sh").path
    ) else {
        throw LauncherError.invalidRepository(repository.path)
    }
    return repository
}

private func bundledQEMUURL() throws -> URL {
    guard let resources = Bundle.main.resourceURL else {
        throw LauncherError.missingResource("Resources")
    }
    let qemu = resources.appendingPathComponent("runtime/bin/BentoQEMU").standardizedFileURL
    guard FileManager.default.isExecutableFile(atPath: qemu.path) else {
        throw LauncherError.missingResource("runtime/bin/BentoQEMU")
    }
    return qemu
}

private func bundledQEMUDataURL(for qemu: URL) throws -> URL {
    let data = qemu.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("share/qemu", isDirectory: true)
    guard FileManager.default.fileExists(atPath: data.appendingPathComponent("efi-virtio.rom").path) else {
        throw LauncherError.missingResource("runtime/share/qemu/efi-virtio.rom")
    }
    return data
}

private func bundledClipboardBridgeURL() throws -> URL {
    guard let executable = Bundle.main.executableURL else {
        throw LauncherError.missingResource("MacOS")
    }
    let bridge = executable.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Helpers/BentoClipboardBridge")
    guard FileManager.default.isExecutableFile(atPath: bridge.path) else {
        throw LauncherError.missingResource("Helpers/BentoClipboardBridge")
    }
    return bridge
}

private func pathIsOpen(_ path: String) -> Bool {
    guard FileManager.default.fileExists(atPath: path) else { return false }
    let lsof = Process()
    lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    lsof.arguments = ["-t", "--", path]
    lsof.standardInput = FileHandle.nullDevice
    lsof.standardOutput = FileHandle.nullDevice
    lsof.standardError = FileHandle.nullDevice
    do {
        try lsof.run()
        lsof.waitUntilExit()
        return lsof.terminationReason == .exit && lsof.terminationStatus == 0
    } catch {
        return false
    }
}

private func vmIsRunning(in repository: URL) -> Bool {
    let artifacts = repository.appendingPathComponent("artifacts", isDirectory: true)
    let descriptorURL = artifacts.appendingPathComponent("runtime.json")
    if let descriptor = try? RuntimeDescriptor.load(from: descriptorURL),
       kill(descriptor.pid, 0) == 0 {
        return true
    }
    return pathIsOpen(artifacts.appendingPathComponent("bento.qcow2").path)
}

private func openLog(in repository: URL) throws -> (URL, FileHandle) {
    let artifacts = repository.appendingPathComponent("artifacts", isDirectory: true)
    try FileManager.default.createDirectory(
        at: artifacts,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: artifacts.path)
    let logURL = artifacts.appendingPathComponent("bento-app.log")
    if !FileManager.default.fileExists(atPath: logURL.path) {
        FileManager.default.createFile(
            atPath: logURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        )
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
    let handle = try FileHandle(forWritingTo: logURL)
    try handle.seekToEnd()
    let stamp = ISO8601DateFormatter().string(from: Date())
    handle.write(Data("\n=== Bento.app launch \(stamp) ===\n".utf8))
    return (logURL, handle)
}

private func runVM(
    from repository: URL,
    qemu: URL,
    qemuData: URL,
    clipboardBridge: URL,
    arguments: [String]
) throws -> Int32 {
    let script = repository.appendingPathComponent("scripts/run-vm.sh")
    let (logURL, log) = try openLog(in: repository)
    defer { try? log.close() }

    let process = Process()
    process.executableURL = script
    process.arguments = arguments
    process.currentDirectoryURL = repository
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = log
    process.standardError = log
    var environment = ProcessInfo.processInfo.environment
    environment["BENTO_LAUNCHED_BY_APP"] = "1"
    environment["BENTO_QEMU"] = qemu.path
    environment["BENTO_QEMU_DATA"] = qemuData.path
    environment["BENTO_CLIPBOARD_BRIDGE"] = clipboardBridge.path
    process.environment = environment

    do {
        try process.run()
    } catch {
        throw NSError(
            domain: "dev.bento.vm.launcher",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "Could not start Bento: \(error.localizedDescription)",
                NSFilePathErrorKey: logURL.path,
            ]
        )
    }
    process.waitUntilExit()
    return process.terminationStatus
}

private final class StartWindowController: NSObject, NSWindowDelegate {
    private let settings: ShareSettings
    private let window: NSWindow
    private let shareCheckbox = NSButton(checkboxWithTitle: "Share a Mac folder at ~/Mac", target: nil, action: nil)
    private let pathLabel = NSTextField(wrappingLabelWithString: "")
    private var selectedURL: URL?
    private var savedSelectionWasUnavailable = false

    init(settings: ShareSettings) {
        self.settings = settings
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 230),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "Start Bento"
        window.isReleasedWhenClosed = false
        window.delegate = self
        buildUI()
        loadSettings()
    }

    private func buildUI() {
        guard let content = window.contentView else { return }
        let title = NSTextField(labelWithString: "Bento")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.frame = NSRect(x: 24, y: 182, width: 300, height: 30)

        let clipboard = NSTextField(labelWithString: "Text and PNG clipboard sharing is automatic.")
        clipboard.textColor = .secondaryLabelColor
        clipboard.frame = NSRect(x: 24, y: 157, width: 450, height: 20)

        shareCheckbox.frame = NSRect(x: 24, y: 116, width: 330, height: 24)
        shareCheckbox.target = self
        shareCheckbox.action = #selector(toggleShare)

        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseFolder))
        choose.bezelStyle = .rounded
        choose.frame = NSRect(x: 384, y: 112, width: 92, height: 30)

        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 2
        pathLabel.frame = NSRect(x: 42, y: 72, width: 432, height: 38)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        cancel.bezelStyle = .rounded
        cancel.frame = NSRect(x: 290, y: 20, width: 90, height: 32)

        let start = NSButton(title: "Start Bento", target: self, action: #selector(start))
        start.keyEquivalent = "\r"
        start.bezelStyle = .rounded
        start.frame = NSRect(x: 384, y: 20, width: 92, height: 32)

        [title, clipboard, shareCheckbox, choose, pathLabel, cancel, start].forEach(content.addSubview)
        window.center()
    }

    private func loadSettings() {
        guard let path = settings.path else {
            shareCheckbox.state = .off
            shareCheckbox.isEnabled = false
            pathLabel.stringValue = "No folder selected"
            pathLabel.textColor = .secondaryLabelColor
            return
        }
        do {
            selectedURL = try SharePathValidator.validate(URL(fileURLWithPath: path, isDirectory: true))
            shareCheckbox.isEnabled = true
            shareCheckbox.state = settings.enabled ? .on : .off
            pathLabel.stringValue = selectedURL!.path
            pathLabel.textColor = .secondaryLabelColor
        } catch {
            selectedURL = nil
            savedSelectionWasUnavailable = true
            shareCheckbox.state = .off
            shareCheckbox.isEnabled = false
            pathLabel.stringValue = "Unavailable: \(path)"
            pathLabel.textColor = .systemRed
        }
    }

    @objc private func toggleShare() {
        guard selectedURL != nil else { shareCheckbox.state = .off; return }
        settings.saveEnabled(shareCheckbox.state == .on)
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder to share with Bento"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if let path = settings.path {
            panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let canonical = try SharePathValidator.validate(url)
            selectedURL = canonical
            savedSelectionWasUnavailable = false
            shareCheckbox.isEnabled = true
            shareCheckbox.state = .on
            pathLabel.stringValue = canonical.path
            pathLabel.textColor = .secondaryLabelColor
            settings.save(path: canonical.path, enabled: true)
        } catch {
            alert(title: "That folder cannot be shared", message: error.localizedDescription)
        }
    }

    @objc private func start() {
        if selectedURL != nil {
            settings.saveEnabled(shareCheckbox.state == .on)
        } else if !savedSelectionWasUnavailable {
            settings.saveEnabled(false)
        }
        NSApp.stopModal(withCode: .OK)
        window.orderOut(nil)
    }

    @objc private func cancel() {
        NSApp.stopModal(withCode: .cancel)
        window.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.stopModal(withCode: .cancel)
    }

    func run() -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        guard NSApp.runModal(for: window) == .OK else { return nil }
        guard shareCheckbox.state == .on else { return URL(string: "bento-no-share:") }
        return selectedURL ?? URL(string: "bento-no-share:")
    }
}

private func withoutIntegrationArguments(_ source: [String]) -> [String] {
    var result: [String] = []
    var index = 0
    while index < source.count {
        switch source[index] {
        case "--share": index += 2
        case "--no-share", "--clipboard", "--no-clipboard": index += 1
        default:
            result.append(source[index])
            index += 1
        }
    }
    return result
}

@main
private enum BentoLauncherMain {
    static func main() {
        do {
            let repository = try repositoryURL()
            let qemu = try bundledQEMUURL()
            let qemuData = try bundledQEMUDataURL(for: qemu)
            let clipboardBridge = try bundledClipboardBridgeURL()

            if CommandLine.arguments.dropFirst().first == "--inspect" {
                print("bundle-id=\(Bundle.main.bundleIdentifier ?? "unknown")")
                print("repository=\(repository.path)")
                print("launcher=\(repository.appendingPathComponent("scripts/run-vm.sh").path)")
                print("qemu=\(qemu.path)")
                print("qemu-data=\(qemuData.path)")
                print("clipboard-bridge=\(clipboardBridge.path)")
                print("accessibility=not-required-for-command-space")
                fflush(stdout)
                exit(0)
            }

            NSApplication.shared.setActivationPolicy(.regular)

            if vmIsRunning(in: repository) {
                alert(
                    title: "Bento is already running",
                    message: "A VM already has Bento's disk open. Shut it down before starting another instance."
                )
                exit(1)
            }

            let controller = StartWindowController(settings: ShareSettings())
            guard let selection = controller.run() else { exit(0) }
            NSApp.setActivationPolicy(.accessory)

            var arguments = withoutIntegrationArguments(Array(CommandLine.arguments.dropFirst()))
            arguments.append("--clipboard")
            if selection.scheme == "bento-no-share" {
                arguments.append("--no-share")
            } else {
                arguments.append(contentsOf: ["--share", selection.path])
            }

            let status = try runVM(
                from: repository,
                qemu: qemu,
                qemuData: qemuData,
                clipboardBridge: clipboardBridge,
                arguments: arguments
            )
            if status != 0 {
                alert(
                    title: "Bento stopped unexpectedly",
                    message: "QEMU exited with status \(status). Details are in artifacts/bento-app.log.",
                    style: .critical
                )
            }
            exit(status)
        } catch {
            alert(title: "Bento could not start", message: error.localizedDescription, style: .critical)
            exit(1)
        }
    }
}
