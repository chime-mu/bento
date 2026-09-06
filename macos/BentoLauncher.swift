import AppKit
import AVFoundation
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

private struct RunningProcess {
    let process: Process
    let log: FileHandle
}

private func startVM(
    from repository: URL,
    qemu: URL,
    qemuData: URL,
    clipboardBridge: URL,
    arguments: [String],
    environment baseEnvironment: [String: String]
) throws -> RunningProcess {
    let script = repository.appendingPathComponent("scripts/run-vm.sh")
    let (logURL, log) = try openLog(in: repository)
    let process = Process()
    process.executableURL = script
    process.arguments = arguments
    process.currentDirectoryURL = repository
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = log
    process.standardError = log
    var environment = baseEnvironment
    environment["BENTO_LAUNCHED_BY_APP"] = "1"
    environment["BENTO_QEMU"] = qemu.path
    environment["BENTO_QEMU_DATA"] = qemuData.path
    environment["BENTO_CLIPBOARD_BRIDGE"] = clipboardBridge.path
    process.environment = environment

    do {
        try process.run()
    } catch {
        try? log.close()
        throw NSError(
            domain: "dev.bento.vm.launcher",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "Could not start Bento: \(error.localizedDescription)",
                NSFilePathErrorKey: logURL.path,
            ]
        )
    }
    return RunningProcess(process: process, log: log)
}

private enum MicrophonePermission {
    static func state() -> MicrophoneAuthorizationState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .restricted
        }
    }

    static func request(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
    }

    static func openSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct StartSelection {
    let sharedFolder: URL?
    let immersive: Bool
}

private final class StartWindowController: NSObject, NSWindowDelegate {
    private let settings: ShareSettings
    private let immersiveSettings: ImmersivePreferenceStore
    private let window: NSWindow
    private let shareCheckbox = NSButton(checkboxWithTitle: "Share a Mac folder at ~/Mac", target: nil, action: nil)
    private let pathLabel = NSTextField(wrappingLabelWithString: "")
    private let microphoneDetail = NSTextField(wrappingLabelWithString: "")
    private let microphoneAction = NSButton(title: "", target: nil, action: nil)
    private let immersiveSwitch = NSSwitch()
    private var selectedURL: URL?
    private var savedSelectionWasUnavailable = false
    private var microphoneRequestInFlight = false

    init(settings: ShareSettings, immersiveSettings: ImmersivePreferenceStore) {
        self.settings = settings
        self.immersiveSettings = immersiveSettings
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 342),
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
        updateMicrophonePresentation()
    }

    private func buildUI() {
        guard let content = window.contentView else { return }
        let title = NSTextField(labelWithString: "Bento")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.frame = NSRect(x: 24, y: 294, width: 300, height: 30)

        let clipboard = NSTextField(labelWithString: "Text and PNG clipboard sharing is automatic.")
        clipboard.textColor = .secondaryLabelColor
        clipboard.frame = NSRect(x: 24, y: 269, width: 480, height: 20)

        let microphoneTitle = NSTextField(labelWithString: "Microphone access")
        microphoneTitle.font = .systemFont(ofSize: 13, weight: .medium)
        microphoneTitle.frame = NSRect(x: 24, y: 226, width: 170, height: 20)
        microphoneDetail.textColor = .secondaryLabelColor
        microphoneDetail.maximumNumberOfLines = 2
        microphoneDetail.frame = NSRect(x: 24, y: 190, width: 350, height: 36)
        microphoneAction.bezelStyle = .rounded
        microphoneAction.target = self
        microphoneAction.action = #selector(handleMicrophoneAction)
        microphoneAction.frame = NSRect(x: 376, y: 207, width: 140, height: 30)

        shareCheckbox.frame = NSRect(x: 24, y: 156, width: 350, height: 24)
        shareCheckbox.target = self
        shareCheckbox.action = #selector(toggleShare)

        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseFolder))
        choose.bezelStyle = .rounded
        choose.frame = NSRect(x: 424, y: 152, width: 92, height: 30)

        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 2
        pathLabel.frame = NSRect(x: 42, y: 116, width: 472, height: 34)

        let immersiveTitle = NSTextField(labelWithString: "Immersive mode")
        immersiveTitle.font = .systemFont(ofSize: 13, weight: .medium)
        immersiveTitle.frame = NSRect(x: 24, y: 82, width: 180, height: 20)
        let immersiveDetail = NSTextField(labelWithString: "Start full screen with the menu bar and Dock hidden.")
        immersiveDetail.textColor = .secondaryLabelColor
        immersiveDetail.frame = NSRect(x: 24, y: 60, width: 420, height: 20)
        immersiveSwitch.target = self
        immersiveSwitch.action = #selector(toggleImmersive)
        immersiveSwitch.setAccessibilityLabel("Immersive mode")
        immersiveSwitch.frame = NSRect(x: 462, y: 71, width: 54, height: 28)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        cancel.bezelStyle = .rounded
        cancel.frame = NSRect(x: 330, y: 16, width: 90, height: 32)

        let start = NSButton(title: "Start Bento", target: self, action: #selector(start))
        start.keyEquivalent = "\r"
        start.bezelStyle = .rounded
        start.frame = NSRect(x: 424, y: 16, width: 92, height: 32)

        [
            title, clipboard, microphoneTitle, microphoneDetail, microphoneAction,
            shareCheckbox, choose, pathLabel, immersiveTitle, immersiveDetail,
            immersiveSwitch, cancel, start,
        ].forEach(content.addSubview)
        window.center()
    }

    private func loadSettings() {
        immersiveSwitch.state = immersiveSettings.load().isEnabled ? .on : .off
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

    private func updateMicrophonePresentation() {
        let presentation = MicrophonePresentation.make(
            state: MicrophonePermission.state(),
            requestInFlight: microphoneRequestInFlight
        )
        microphoneDetail.stringValue = presentation.detail
        microphoneAction.title = presentation.actionTitle ?? "Allowed"
        microphoneAction.isEnabled = presentation.action != nil && !microphoneRequestInFlight
        microphoneAction.isHidden = presentation.granted || presentation.actionTitle == nil
    }

    @objc private func handleMicrophoneAction() {
        let presentation = MicrophonePresentation.make(state: MicrophonePermission.state())
        switch presentation.action {
        case .request:
            microphoneRequestInFlight = true
            updateMicrophonePresentation()
            MicrophonePermission.request { [weak self] _ in
                DispatchQueue.main.async {
                    self?.microphoneRequestInFlight = false
                    self?.updateMicrophonePresentation()
                }
            }
        case .openSettings:
            MicrophonePermission.openSettings()
        case nil:
            break
        }
    }

    @objc private func toggleImmersive() {
        immersiveSettings.save(.init(isEnabled: immersiveSwitch.state == .on))
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

    func windowDidBecomeKey(_ notification: Notification) {
        updateMicrophonePresentation()
    }

    func run() -> StartSelection? {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        guard NSApp.runModal(for: window) == .OK else { return nil }
        let folder = shareCheckbox.state == .on ? selectedURL : nil
        return StartSelection(
            sharedFolder: folder,
            immersive: immersiveSwitch.state == .on
        )
    }
}

private func withoutAppOwnedArguments(_ source: [String]) -> [String] {
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

/// Owns the shell launcher, QMP sleep policy, audio bridge, and AppKit event
/// loop for exactly one VM run.
private final class RunningVMController: NSObject, NSApplicationDelegate {
    private let running: RunningProcess
    private let runtimeDescriptorURL: URL
    private let hostSleepCoordinator = VMHostSleepCoordinator()
    private var runtimePoll: Timer?
    private var powerObservers: [NSObjectProtocol] = []
    private var audioBridge: NativeAudioBridge?
    private var startupDeadline = Date().addingTimeInterval(10)
    private var startupFailure: String?
    private var stopping = false
    private var terminationPending = false
    private var virtualMachineReady = false
    private var processExitHandled = false
    private(set) var exitStatus: Int32 = 0

    init(repository: URL, running: RunningProcess) {
        self.running = running
        runtimeDescriptorURL = repository
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent("runtime.json")
        super.init()
    }

    func start() {
        NSApp.delegate = self
        observePowerEvents()
        running.process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                self?.processDidExit(process)
            }
        }
        if !running.process.isRunning {
            processDidExit(running.process)
            return
        }
        runtimePoll = Timer.scheduledTimer(
            timeInterval: 0.1,
            target: self,
            selector: #selector(checkRuntimeReadiness),
            userInfo: nil,
            repeats: true
        )
        checkRuntimeReadiness()
    }

    @objc private func checkRuntimeReadiness() {
        guard !virtualMachineReady, !stopping else { return }
        if let descriptor = try? RuntimeDescriptor.load(from: runtimeDescriptorURL) {
            do {
                try hostSleepCoordinator.connect(to: descriptor.qmp)
                virtualMachineReady = true
                runtimePoll?.invalidate()
                runtimePoll = nil
                startAudioBridgeIfAvailable(descriptor)
                NSApp.setActivationPolicy(.accessory)
                return
            } catch {
                if Date() < startupDeadline { return }
                failSecureControl("Bento could not establish secure QMP control: \(error.localizedDescription)")
                return
            }
        }
        if Date() >= startupDeadline {
            failSecureControl("Bento did not receive its private QMP endpoint in time.")
        }
    }

    private func failSecureControl(_ detail: String) {
        guard startupFailure == nil else { return }
        startupFailure = detail
        stopping = true
        runtimePoll?.invalidate()
        runtimePoll = nil
        running.process.terminate()
    }

    private func startAudioBridgeIfAvailable(_ descriptor: RuntimeDescriptor) {
        guard descriptor.audio,
              let socket = descriptor.audioSocket,
              let routes = descriptor.audioRoutes else { return }
        do {
            let bridge = try NativeAudioBridge(
                targetPID: descriptor.pid,
                socketPath: socket,
                routeDirectoryPath: routes
            )
            audioBridge = bridge
            DispatchQueue.global(qos: .userInitiated).async { [weak bridge] in
                guard let bridge else { return }
                do {
                    try bridge.run()
                } catch {
                    fputs("Bento audio bridge stopped: \(error.localizedDescription)\n", stderr)
                }
            }
        } catch {
            // Audio route/catalog failure is deliberately non-fatal. QEMU's
            // SDL backend remains on its last effective or system-default route.
            fputs("Bento audio bridge unavailable: \(error.localizedDescription)\n", stderr)
        }
    }

    private func observePowerEvents() {
        let center = NSWorkspace.shared.notificationCenter
        powerObservers = [
            center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in self?.prepareForHostSleep() },
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in self?.beginResumeAfterHostWake() },
        ]
    }

    /// Workspace notifications may hold sleep briefly; keep this synchronous
    /// so STOP can be observed before Hypervisor.framework freezes.
    private func prepareForHostSleep() {
        do {
            try hostSleepCoordinator.prepareForHostSleep(
                vmIsRunning: running.process.isRunning,
                isStopping: stopping
            )
        } catch {
            fputs("Bento could not confirm the VM pause before Mac sleep: \(error.localizedDescription)\n", stderr)
        }
    }

    private func beginResumeAfterHostWake() {
        hostSleepCoordinator.cancelWakeRetry()
        resumeAfterHostWake()
    }

    private func resumeAfterHostWake() {
        do {
            try hostSleepCoordinator.resumeAfterHostWake(
                vmIsRunning: running.process.isRunning,
                isStopping: stopping
            )
            hostSleepCoordinator.cancelWakeRetry()
        } catch let controlError as VMHostSleepControlError {
            // An abnormal QEMU stop supersedes host-sleep ownership and must
            // never be resumed automatically.
            fputs("Bento refused an unsafe wake resume: \(controlError.localizedDescription)\n", stderr)
        } catch {
            fputs("Bento could not reconnect after Mac wake: \(error.localizedDescription)\n", stderr)
            guard hostSleepCoordinator.pausedForHostSleep,
                  running.process.isRunning,
                  !stopping else { return }
            if !hostSleepCoordinator.scheduleWakeRetry({ [weak self] in
                self?.resumeAfterHostWake()
            }) {
                presentWakeRecovery(error)
            }
        }
    }

    private func presentWakeRecovery(_ error: Error) {
        guard running.process.isRunning,
              !stopping,
              hostSleepCoordinator.pausedForHostSleep else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSAlert()
        panel.alertStyle = .critical
        panel.messageText = "Bento is still paused"
        panel.informativeText = "Bento could not reconnect after this Mac woke, so the VM remains paused to protect its state. Retry, or quit the VM. (\(error.localizedDescription))"
        panel.addButton(withTitle: "Retry")
        panel.addButton(withTitle: "Quit VM")
        if panel.runModal() == .alertFirstButtonReturn {
            beginResumeAfterHostWake()
        } else {
            stopVM()
        }
    }

    private func stopVM() {
        guard running.process.isRunning else { return }
        stopping = true
        hostSleepCoordinator.cancelWakeRetry()
        running.process.terminate()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard running.process.isRunning else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        stopVM()
        return .terminateLater
    }

    private func processDidExit(_ process: Process) {
        guard !processExitHandled else { return }
        processExitHandled = true
        runtimePoll?.invalidate()
        runtimePoll = nil
        audioBridge?.stop()
        audioBridge = nil
        hostSleepCoordinator.disconnect()
        for observer in powerObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        powerObservers.removeAll()
        try? running.log.close()
        exitStatus = process.terminationStatus

        if let startupFailure {
            alert(title: "Bento could not start", message: startupFailure, style: .critical)
            if exitStatus == 0 { exitStatus = 1 }
        } else if exitStatus != 0 && !stopping {
            alert(
                title: "Bento stopped unexpectedly",
                message: "QEMU exited with status \(exitStatus). Details are in artifacts/bento-app.log.",
                style: .critical
            )
        }

        if terminationPending {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        NSApp.stop(nil)
    }
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

            let controller = StartWindowController(
                settings: ShareSettings(),
                immersiveSettings: ImmersivePreferenceStore()
            )
            guard let selection = controller.run() else { exit(0) }

            var arguments = withoutAppOwnedArguments(Array(CommandLine.arguments.dropFirst()))
            arguments = BentoLaunchArgumentPolicy.normalizedForApp(
                arguments,
                immersive: selection.immersive
            )
            arguments.append("--clipboard")
            if let sharedFolder = selection.sharedFolder {
                arguments.append(contentsOf: ["--share", sharedFolder.path])
            } else {
                arguments.append("--no-share")
            }

            var environment = ProcessInfo.processInfo.environment
            environment = AudioLaunchConfiguration.make(
                baseEnvironment: environment,
                preferences: AudioRoutingPreferenceStore().load(),
                catalog: CoreAudioHostAudioDeviceProvider().catalog()
            ).environment
            let running = try startVM(
                from: repository,
                qemu: qemu,
                qemuData: qemuData,
                clipboardBridge: clipboardBridge,
                arguments: arguments,
                environment: environment
            )
            let lifecycle = RunningVMController(repository: repository, running: running)
            lifecycle.start()
            NSApp.run()
            exit(lifecycle.exitStatus)
        } catch {
            alert(title: "Bento could not start", message: error.localizedDescription, style: .critical)
            exit(1)
        }
    }
}
