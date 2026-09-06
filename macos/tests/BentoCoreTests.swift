import AppKit
import Darwin
import Foundation

private enum TestFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case .failed(let message): return message }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure.failed(message) }
}

private func expectError<T>(_ expected: SharePathError, _ body: () throws -> T) throws {
    do {
        _ = try body()
        throw TestFailure.failed("expected \(expected)")
    } catch let error as SharePathError {
        try expect(error == expected, "expected \(expected), got \(error)")
    }
}

private func testPathValidationAndPersistence() throws {
    let manager = FileManager.default
    let root = URL(fileURLWithPath: manager.currentDirectoryPath)
        .appendingPathComponent(".bento-swift-tests-\(UUID().uuidString)")
    defer { try? manager.removeItem(at: root) }
    try manager.createDirectory(at: root, withIntermediateDirectories: false)
    let valid = root.appendingPathComponent("Shared ünicode")
    try manager.createDirectory(at: valid, withIntermediateDirectories: false)
    let canonical = try SharePathValidator.validate(valid)
    try expect(canonical.path == valid.path, "valid folder was not preserved")

    let symlink = root.appendingPathComponent("linked")
    try manager.createSymbolicLink(at: symlink, withDestinationURL: valid)
    try expectError(.symbolicLink) { try SharePathValidator.validate(symlink) }
    try expectError(.unsafeCharacters) {
        try SharePathValidator.validate(root.appendingPathComponent("bad,name"))
    }
    try expectError(.homeDirectory) {
        try SharePathValidator.validate(manager.homeDirectoryForCurrentUser)
    }

    let suite = "dev.bento.vm.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = ShareSettings(defaults: defaults)
    try expect(settings.path == nil && !settings.enabled, "first-launch defaults are not disabled")
    settings.save(path: canonical.path, enabled: true)
    let loaded = ShareSettings(defaults: defaults)
    try expect(loaded.path == canonical.path && loaded.enabled, "share settings did not persist")
}

private func testFramingAndLimits() throws {
    let content = try ClipboardContent(kind: .text, data: Data("fragmented".utf8))
    let line = try ClipboardEvent.clipboard(content).encodedLine()
    var framer = NDJSONFramer()
    var output: [Data] = []
    for byte in line {
        output += try framer.append(Data([byte]))
    }
    try expect(output.count == 1, "fragmented message did not yield exactly one line")
    let decoded = try ClipboardEvent.decode(line: output[0])
    try expect(decoded == .clipboard(content), "decoded message changed")

    do {
        _ = try ClipboardContent(kind: .png, data: Data(repeating: 0, count: bentoClipboardPayloadLimit + 1))
        throw TestFailure.failed("oversized decoded payload was accepted")
    } catch ClipboardProtocolError.oversized {
        // expected
    }
    var oversizedFramer = NDJSONFramer()
    do {
        _ = try oversizedFramer.append(Data(repeating: 65, count: bentoClipboardLineLimit + 1))
        throw TestFailure.failed("oversized wire message was accepted")
    } catch ClipboardProtocolError.oversized {
        // expected
    }
}

private func testPasteboardConversion() throws {
    let text = try MacPasteboard.preferredContent(
        text: "text wins",
        png: Data([137, 80, 78, 71]),
        bitmapData: nil
    )
    try expect(text?.kind == .text, "text did not win over an image representation")
    try expect(String(data: text!.data, encoding: .utf8) == "text wins", "pasteboard text changed")

    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 1,
        pixelsHigh: 1,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 4,
        bitsPerPixel: 32
    ), let pixels = bitmap.bitmapData else {
        throw TestFailure.failed("could not create bitmap fixture")
    }
    pixels[0] = 0x20; pixels[1] = 0x40; pixels[2] = 0x80; pixels[3] = 0xff
    let image = try MacPasteboard.preferredContent(
        text: nil,
        png: nil,
        bitmapData: bitmap.tiffRepresentation!
    )
    try expect(image?.kind == .png, "TIFF was not converted to PNG")
    try expect(image?.data.starts(with: Data([137, 80, 78, 71, 13, 10, 26, 10])) == true,
               "converted data has no PNG signature")
}

private func testEchoSuppression() throws {
    let a = try ClipboardContent(kind: .text, data: Data("a".utf8)).fingerprint
    let b = try ClipboardContent(kind: .text, data: Data("b".utf8)).fingerprint
    var suppressor = ClipboardEchoSuppressor()
    try expect(suppressor.shouldSendLocal(a), "first local clipboard was suppressed")
    try expect(!suppressor.shouldApplyRemote(a), "local echo was applied")
    try expect(suppressor.shouldApplyRemote(b), "new remote clipboard was suppressed")
    try expect(!suppressor.shouldSendLocal(b), "remote echo was sent back")
    try expect(suppressor.shouldSendLocal(a), "later genuine local change was suppressed")

    var repeated = ClipboardEchoSuppressor()
    try expect(repeated.shouldSendLocal(a), "initial repeated-value fixture was suppressed")
    try expect(repeated.shouldApplyRemote(b), "remote repeated-value fixture was suppressed")
    try expect(
        repeated.shouldSendLocal(a),
        "local return to a previously sent value was mistaken for an echo"
    )
}

private func testImmersivePreferencesAndArguments() throws {
    let suite = "dev.bento.vm.immersive-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ImmersivePreferenceStore(defaults: defaults)
    try expect(store.load() == .defaults, "immersive mode did not default on")
    store.save(.init(isEnabled: false))
    try expect(!ImmersivePreferenceStore(defaults: defaults).load().isEnabled,
               "immersive preference did not persist")

    let corrupt = Data("future-or-corrupt".utf8)
    defaults.set(corrupt, forKey: ImmersivePreferenceStore.key)
    try expect(store.load() == .defaults, "corrupt immersive preference did not fail safe")
    try expect(defaults.data(forKey: ImmersivePreferenceStore.key) == corrupt,
               "corrupt immersive preference was overwritten")
    let future = try JSONSerialization.data(withJSONObject: [
        "schemaVersion": 2,
        "isEnabled": false,
    ])
    defaults.set(future, forKey: ImmersivePreferenceStore.key)
    try expect(store.load() == .defaults, "future immersive preference did not fail safe")
    try expect(defaults.data(forKey: ImmersivePreferenceStore.key) == future,
               "future immersive preference was overwritten")

    try expect(
        BentoLaunchArgumentPolicy.normalizedForApp(["--windowed", "--no-gl"], immersive: true)
            == ["--no-gl"],
        "saved immersive choice did not override incoming windowed flag"
    )
    try expect(
        BentoLaunchArgumentPolicy.normalizedForApp([], immersive: false) == ["--windowed"],
        "windowed launch argument was not composed"
    )
}

private func testMicrophonePresentation() throws {
    let undecided = MicrophonePresentation.make(state: .notDetermined)
    try expect(undecided.action == .request && undecided.actionTitle == "Allow",
               "undecided microphone state has no explicit Allow action")
    try expect(undecided.detail.contains("Speaker playback works"),
               "microphone prompt incorrectly implies playback is blocked")
    let denied = MicrophonePresentation.make(state: .denied)
    try expect(denied.action == .openSettings && denied.actionTitle == "Open System Settings",
               "denied microphone state has no settings action")
    try expect(MicrophonePresentation.make(state: .authorized).granted,
               "authorized microphone state is not granted")
}

private func testAudioPreferencesCatalogAndProtocol() throws {
    let suite = "dev.bento.vm.audio-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AudioRoutingPreferenceStore(defaults: defaults)
    try expect(store.load() == .systemDefaults, "audio did not default both routes")
    let saved = AudioRoutingPreferences(
        output: .device(uid: "out", lastKnownName: "Display Audio"),
        input: .device(uid: "in", lastKnownName: "Desk Mic")
    )
    store.save(saved)
    try expect(store.load() == saved, "independent audio routes did not persist")
    let corrupt = Data("unreadable-audio-preferences".utf8)
    defaults.set(corrupt, forKey: AudioRoutingPreferenceStore.key)
    try expect(store.load() == .systemDefaults,
               "corrupt audio preferences did not fall back to system defaults")
    try expect(defaults.data(forKey: AudioRoutingPreferenceStore.key) == corrupt,
               "corrupt audio preferences were overwritten")
    let future = try JSONSerialization.data(withJSONObject: [
        "schemaVersion": 2,
        "output": ["kind": "systemDefault", "uid": NSNull(), "lastKnownName": NSNull()],
        "input": ["kind": "systemDefault", "uid": NSNull(), "lastKnownName": NSNull()],
    ])
    defaults.set(future, forKey: AudioRoutingPreferenceStore.key)
    try expect(store.load() == .systemDefaults,
               "future audio preferences did not fall back to system defaults")
    try expect(defaults.data(forKey: AudioRoutingPreferenceStore.key) == future,
               "future audio preferences were overwritten")
    store.save(saved)

    let catalog = HostAudioDeviceCatalog.make(from: [
        .init(uid: "out", outputName: "Display Audio", inputName: "Desk Mic"),
        .init(uid: "out-2", outputName: "Display Audio ", inputName: "Desk Mic"),
    ])
    try expect(catalog.device(uid: "out-2", direction: .output)?.sdlName == "Display Audio (2)",
               "duplicate SDL output names were not suffixed")
    try expect(catalog.device(uid: "out-2", direction: .input)?.sdlName == "Desk Mic (2)",
               "duplicate SDL input names were not suffixed independently")

    let unavailable = AudioLaunchConfiguration.make(
        baseEnvironment: ["SDL_AUDIO_DEVICE_NAME": "unsafe-global"],
        preferences: .init(
            output: .device(uid: "missing", lastKnownName: "Disconnected"),
            input: .systemDefault
        ),
        catalog: .empty
    )
    try expect(unavailable.routes.outputSDLName == nil && unavailable.environment.isEmpty,
               "missing audio device did not fall back to system default")

    let request = NativeAudioRouteRequest.decode(Data(
        #"{"deviceUID":"out","direction":"output","type":"select"}"#.utf8
    ))
    try expect(request == .init(direction: .output, deviceUID: "out"),
               "strict audio selection request did not decode")
    try expect(NativeAudioRouteRequest.decode(Data(
        #"{"deviceUID":"out","direction":"output","extra":true,"type":"select"}"#.utf8
    )) == nil, "audio selection accepted an extra protocol field")
    let catalogLine = try NativeAudioCatalogMessage.encode(catalog: catalog, preferences: saved)
    try expect(catalogLine.last == 0x0a, "audio catalog was not newline-delimited")
}

private func testPrivateAudioRouteFiles() throws {
    let manager = FileManager.default
    let directory = manager.temporaryDirectory
        .appendingPathComponent("bento-audio-route-tests.\(UUID().uuidString)")
    try manager.createDirectory(
        at: directory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    defer { try? manager.removeItem(at: directory) }
    let routeStore = try NativeAudioRouteFileStore(directoryPath: directory.path)
    try routeStore.publish("Studio Display", for: .output)
    try routeStore.publish(nil, for: .input)
    let output = try String(
        contentsOf: directory.appendingPathComponent("output"),
        encoding: .utf8
    )
    let input = try String(
        contentsOf: directory.appendingPathComponent("input"),
        encoding: .utf8
    )
    try expect(output == "U3R1ZGlvIERpc3BsYXk=\n", "output route was not canonical base64")
    try expect(input == "default\n", "default route sentinel changed")
}

private func readJSONLine(_ descriptor: Int32) throws -> [String: Any] {
    var bytes = Data()
    while true {
        var byte: UInt8 = 0
        let count = Darwin.read(descriptor, &byte, 1)
        guard count == 1 else { throw TestFailure.failed("QMP test socket closed") }
        if byte == 0x0a {
            guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                throw TestFailure.failed("QMP test received non-object JSON")
            }
            return object
        }
        if byte != 0x0d { bytes.append(byte) }
    }
}

private func testQMPReplyEventCorrelation() throws {
    var descriptors: [Int32] = [0, 0]
    try expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0,
               "could not create QMP test socketpair")
    let completed = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        defer { Darwin.close(descriptors[1]); completed.signal() }
        do {
            try QMPConnection.writeJSON(["QMP": ["version": [:]]], to: descriptors[1])
            let capabilities = try readJSONLine(descriptors[1])
            try QMPConnection.writeJSON(["event": "RTC_CHANGE"], to: descriptors[1])
            try QMPConnection.writeJSON(["return": [:], "id": capabilities["id"]!], to: descriptors[1])
            let stop = try readJSONLine(descriptors[1])
            try QMPConnection.writeJSON(["event": "STOP"], to: descriptors[1])
            try QMPConnection.writeJSON(["return": [:], "id": stop["id"]!], to: descriptors[1])
        } catch {
            // The assertions below will expose an incomplete transcript.
        }
    }
    let connection = try QMPConnection(
        connectedDescriptor: descriptors[0],
        identifierPrefix: "bento-test"
    )
    let execution = try connection.executeCapturingEvents("stop")
    connection.close()
    try expect(execution.events == ["STOP"], "QMP event was not correlated with its reply")
    try expect(completed.wait(timeout: .now() + 2) == .success, "QMP test server did not finish")
}

private final class FakeSleepController: VMHostSleepControlling {
    var pauseResult: Bool
    var pauseError: Error?
    var resumeError: Error?
    var pauseCalls = 0
    var resumeCalls = 0
    init(pauseResult: Bool, pauseError: Error? = nil, resumeError: Error? = nil) {
        self.pauseResult = pauseResult
        self.pauseError = pauseError
        self.resumeError = resumeError
    }
    func pauseIfRunning() throws -> Bool {
        pauseCalls += 1
        if let pauseError { throw pauseError }
        return pauseResult
    }
    func resume() throws {
        resumeCalls += 1
        if let resumeError { throw resumeError }
    }
    func close() {}
}

private func testPauseOwnership() throws {
    let owned = FakeSleepController(pauseResult: true)
    let coordinator = VMHostSleepCoordinator()
    coordinator.attach(owned)
    try coordinator.prepareForHostSleep(vmIsRunning: true, isStopping: false)
    try coordinator.prepareForHostSleep(vmIsRunning: true, isStopping: false)
    try coordinator.resumeAfterHostWake(vmIsRunning: true, isStopping: false)
    try expect(owned.pauseCalls == 1 && owned.resumeCalls == 1,
               "one host pause did not own exactly one resume")

    let prePaused = FakeSleepController(pauseResult: false)
    coordinator.attach(prePaused)
    try coordinator.prepareForHostSleep(vmIsRunning: true, isStopping: false)
    try coordinator.resumeAfterHostWake(vmIsRunning: true, isStopping: false)
    try expect(prePaused.resumeCalls == 0, "a pre-existing VM pause was resumed")

    let ambiguous = FakeSleepController(
        pauseResult: false,
        pauseError: VMHostSleepControlError.pauseOutcomeUnknown("host slept")
    )
    coordinator.attach(ambiguous)
    do {
        try coordinator.prepareForHostSleep(vmIsRunning: true, isStopping: false)
        throw TestFailure.failed("ambiguous pause outcome did not surface")
    } catch is VMHostSleepControlError {
        // Expected: ownership is retained so wake can resolve the outcome.
    }
    try expect(coordinator.pausedForHostSleep,
               "ambiguous pause outcome did not retain recovery ownership")
    try coordinator.resumeAfterHostWake(vmIsRunning: true, isStopping: false)
    try expect(ambiguous.resumeCalls == 1 && !coordinator.pausedForHostSleep,
               "ambiguous pause outcome was not recovered exactly once")

    let abnormal = FakeSleepController(
        pauseResult: true,
        resumeError: VMHostSleepControlError.unsafeResumeState("io-error")
    )
    coordinator.attach(abnormal)
    try coordinator.prepareForHostSleep(vmIsRunning: true, isStopping: false)
    do {
        try coordinator.resumeAfterHostWake(vmIsRunning: true, isStopping: false)
        throw TestFailure.failed("unsafe VM run state was resumed")
    } catch is VMHostSleepControlError {
        // Expected: the coordinator relinquishes rather than retrying cont.
    }
    try expect(!coordinator.pausedForHostSleep,
               "unsafe resume state kept stale host-sleep ownership")

    var retry = VMHostWakeRetryPolicy()
    try expect([retry.nextDelay(), retry.nextDelay(), retry.nextDelay(), retry.nextDelay()]
                   == [0.25, 0.75, 1.5, 3.0], "wake retry schedule changed")
    try expect(retry.nextDelay() == nil, "wake retry schedule was not bounded")
}

@main
private enum BentoCoreTests {
    static func main() throws {
        _ = NSApplication.shared
        try testPathValidationAndPersistence()
        try testFramingAndLimits()
        try testPasteboardConversion()
        try testEchoSuppression()
        try testImmersivePreferencesAndArguments()
        try testMicrophonePresentation()
        try testAudioPreferencesCatalogAndProtocol()
        try testPrivateAudioRouteFiles()
        try testQMPReplyEventCorrelation()
        try testPauseOwnership()
        print("Bento macOS core tests passed")
    }
}
