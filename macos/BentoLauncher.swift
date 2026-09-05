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
    style: NSAlert.Style = .warning,
    buttons: [String] = ["OK"]
) -> NSApplication.ModalResponse {
    NSApp.setActivationPolicy(.accessory)
    NSApp.activate(ignoringOtherApps: true)

    let panel = NSAlert()
    panel.alertStyle = style
    panel.messageText = title
    panel.informativeText = message
    for button in buttons {
        panel.addButton(withTitle: button)
    }
    return panel.runModal()
}

private func repositoryURL() throws -> URL {
    guard let pathURL = Bundle.main.url(
        forResource: "repository-path",
        withExtension: nil
    ) else {
        throw LauncherError.missingResource("repository-path")
    }

    let path = try String(contentsOf: pathURL, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let repository = URL(fileURLWithPath: path, isDirectory: true)
        .standardizedFileURL
    let launcher = repository.appendingPathComponent("scripts/run-vm.sh")
    guard FileManager.default.isExecutableFile(atPath: launcher.path) else {
        throw LauncherError.invalidRepository(repository.path)
    }
    return repository
}

private func bundledQEMUURL() throws -> URL {
    guard let resources = Bundle.main.resourceURL else {
        throw LauncherError.missingResource("Resources")
    }
    let qemu = resources
        .appendingPathComponent("runtime/bin/BentoQEMU")
        .standardizedFileURL
    guard FileManager.default.isExecutableFile(atPath: qemu.path) else {
        throw LauncherError.missingResource("runtime/bin/BentoQEMU")
    }
    return qemu
}

private func bundledQEMUDataURL(for qemu: URL) throws -> URL {
    let data = qemu
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("share/qemu", isDirectory: true)
    let optionROM = data.appendingPathComponent("efi-virtio.rom")
    guard FileManager.default.fileExists(atPath: optionROM.path) else {
        throw LauncherError.missingResource("runtime/share/qemu/efi-virtio.rom")
    }
    return data
}

private func qmpSocketIsOpen(in repository: URL) -> Bool {
    let socket = repository.appendingPathComponent("artifacts/qmp.sock").path
    guard FileManager.default.fileExists(atPath: socket) else { return false }

    let lsof = Process()
    lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    lsof.arguments = ["-t", "--", socket]
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

private func openLog(in repository: URL) throws -> (URL, FileHandle) {
    let artifacts = repository.appendingPathComponent("artifacts", isDirectory: true)
    try FileManager.default.createDirectory(
        at: artifacts,
        withIntermediateDirectories: true
    )
    let logURL = artifacts.appendingPathComponent("bento-app.log")
    if !FileManager.default.fileExists(atPath: logURL.path) {
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
    }
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
    arguments: [String]
) throws -> Int32 {
    let script = repository.appendingPathComponent("scripts/run-vm.sh")
    let (logURL, log) = try openLog(in: repository)
    defer { try? log.close() }

    let process = Process()
    // Execute the script through its own `#!/usr/bin/env bash` shebang. In particular,
    // do not force it through zsh: run-vm.sh uses BASH_SOURCE to locate the checkout.
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

    // Keeping this process alive leaves Bento.app at the root of QEMU's process tree and
    // lets the native wrapper report an orderly or failed VM exit.
    process.waitUntilExit()
    return process.terminationStatus
}

NSApplication.shared.setActivationPolicy(.accessory)

do {
    let repository = try repositoryURL()
    let qemu = try bundledQEMUURL()
    let qemuData = try bundledQEMUDataURL(for: qemu)

    if CommandLine.arguments.dropFirst().first == "--inspect" {
        print("bundle-id=\(Bundle.main.bundleIdentifier ?? "unknown")")
        print("repository=\(repository.path)")
        print("launcher=\(repository.appendingPathComponent("scripts/run-vm.sh").path)")
        print("qemu=\(qemu.path)")
        print("qemu-data=\(qemuData.path)")
        print("accessibility=not-required-for-command-space")
        fflush(stdout)
        exit(0)
    }

    if qmpSocketIsOpen(in: repository) {
        _ = alert(
            title: "Bento is already running",
            message: "A VM is already using Bento's QMP socket. Shut down the existing VM, then reopen Bento.app. This prevents a second launch from disturbing the running instance."
        )
        exit(1)
    }

    let status = try runVM(
        from: repository,
        qemu: qemu,
        qemuData: qemuData,
        arguments: Array(CommandLine.arguments.dropFirst())
    )
    if status != 0 {
        _ = alert(
            title: "Bento stopped unexpectedly",
            message: "QEMU exited with status \(status). Details are in artifacts/bento-app.log.",
            style: .critical
        )
    }
    exit(status)
} catch {
    _ = alert(
        title: "Bento could not start",
        message: error.localizedDescription,
        style: .critical
    )
    exit(1)
}
