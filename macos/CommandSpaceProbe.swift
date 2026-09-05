import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Darwin
import Foundation

private let spaceKeyCode: Int64 = 49
private let leftCommandKeyCode: Int64 = 55
private let rightCommandKeyCode: Int64 = 54
private let spotlightSearchHotKeyID: Int32 = 64
private let carbonHotKeySignature: OSType = 0x4253_5043 // "BSPC"
private let carbonHotKeyIdentifier = EventHotKeyID(
    signature: carbonHotKeySignature,
    id: 1
)

private typealias SetSymbolicHotKeyEnabled = @convention(c) (
    Int32,
    Bool
) -> Int32
private typealias IsSymbolicHotKeyEnabled = @convention(c) (Int32) -> Bool

private func retainedEvent(_ event: CGEvent) -> Unmanaged<CGEvent> {
    Unmanaged.passUnretained(event)
}

private let keyboardTapCallback: CGEventTapCallBack = {
    _, type, event, userInfo in
    guard let userInfo else { return retainedEvent(event) }
    let probe = Unmanaged<CommandSpaceProbe>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    return probe.handle(type: type, event: event)
}

private let carbonHotKeyCallback: EventHandlerUPP = {
    _, event, userInfo in
    guard let event, let userInfo else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let result = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard result == noErr,
          hotKeyID.signature == carbonHotKeySignature,
          hotKeyID.id == carbonHotKeyIdentifier.id
    else {
        return OSStatus(eventNotHandledErr)
    }
    let probe = Unmanaged<CommandSpaceProbe>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    probe.handleCarbonCommandSpace()
    return noErr
}

private final class CommandSpaceProbe: NSObject, NSApplicationDelegate,
    NSWindowDelegate
{
    private let tracePath = "/tmp/bento-command-space-probe.log"
    private var traceFile: FileHandle?
    private var window: NSWindow!
    private var status: NSTextField!
    private var detail: NSTextField!
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var permissionTimer: Timer?
    private var commandDownWithoutSpace = false
    private var swallowingSpace = false
    private var lastPermissionState: Bool?
    private var dynamicLibraryHandles: [UnsafeMutableRawPointer] = []
    private var setSymbolicHotKeyEnabled: SetSymbolicHotKeyEnabled?
    private var isSymbolicHotKeyEnabled: IsSymbolicHotKeyEnabled?
    private var spotlightWasEnabled: Bool?
    private var spotlightSuppressed = false
    private var carbonEventHandler: EventHandlerRef?
    private var carbonHotKey: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        openTrace()
        trace("LAUNCH bundle=dev.bento.command-space-probe pid=\(ProcessInfo.processInfo.processIdentifier)")
        loadSymbolicHotKeyAPI()
        installCarbonEventHandler()
        makeWindow()
        suppressSpotlight(reason: "launch")
        checkPermissionAndInstallTap(prompt: false)
    }

    func applicationWillTerminate(_ notification: Notification) {
        restoreSpotlight(reason: "terminate")
        if let carbonEventHandler {
            RemoveEventHandler(carbonEventHandler)
            self.carbonEventHandler = nil
        }
        trace("TERMINATE")
        try? traceFile?.close()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if window?.isKeyWindow == true {
            suppressSpotlight(reason: "application-became-active")
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        restoreSpotlight(reason: "application-resigned-active")
    }

    func windowDidBecomeKey(_ notification: Notification) {
        suppressSpotlight(reason: "window-became-key")
    }

    func windowDidResignKey(_ notification: Notification) {
        restoreSpotlight(reason: "window-resigned-key")
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        true
    }

    private func makeWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 300),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Command-Space Probe"
        window.delegate = self
        window.center()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false

        status = NSTextField(labelWithString: "Starting…")
        status.font = .systemFont(ofSize: 30, weight: .bold)
        status.alignment = .center
        status.maximumNumberOfLines = 2

        detail = NSTextField(labelWithString: "")
        detail.font = .systemFont(ofSize: 15)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.maximumNumberOfLines = 4

        stack.addArrangedSubview(status)
        stack.addArrangedSubview(detail)
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -32),
            stack.centerYAnchor.constraint(equalTo: window.contentView!.centerYAnchor),
        ])

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func checkPermissionAndInstallTap(prompt: Bool) {
        let trusted = AXIsProcessTrusted()
        if trusted != lastPermissionState {
            trace("ACCESSIBILITY allowed=\(trusted ? 1 : 0)")
            lastPermissionState = trusted
        }
        guard trusted else {
            if carbonHotKey != nil {
                show(
                    "Ready via Carbon",
                    detail: "Press ⌘Space. Accessibility is not needed for this part of the experiment."
                )
            } else {
                show(
                    "Could not register ⌘Space",
                    detail: "Neither Carbon nor the Accessibility event-tap path is available."
                )
            }
            if prompt {
                trace("ACCESSIBILITY requesting-system-prompt")
                let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            }
            if permissionTimer == nil {
                permissionTimer = Timer.scheduledTimer(
                    withTimeInterval: 0.5,
                    repeats: true
                ) { [weak self] _ in
                    self?.checkPermissionAndInstallTap(prompt: false)
                }
            }
            return
        }

        permissionTimer?.invalidate()
        permissionTimer = nil
        installTap()
    }

    private func installTap() {
        guard eventTap == nil else { return }

        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
            | CGEventMask(1) << CGEventType.keyUp.rawValue
            | CGEventMask(1) << CGEventType.flagsChanged.rawValue
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: keyboardTapCallback,
            userInfo: context
        ) else {
            trace("TAP create=failed location=hid place=head options=filtering")
            show(
                "Could not create the HID tap",
                detail: "Accessibility is enabled, but macOS refused the keyboard event tap. Quit and reopen this app."
            )
            return
        }

        eventTap = tap
        eventTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        trace("TAP create=ok location=hid place=head options=filtering")
        show(
            "Ready",
            detail: "Spotlight is disabled only while this window is focused. Press ⌘Space once."
        )
    }

    private func loadSymbolicHotKeyAPI() {
        if let processHandle = dlopen(nil, RTLD_LAZY) {
            dynamicLibraryHandles.append(processHandle)
        }
        if let skyLightHandle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY
        ) {
            dynamicLibraryHandles.append(skyLightHandle)
        }

        for handle in dynamicLibraryHandles where setSymbolicHotKeyEnabled == nil {
            for name in [
                "CGSSetSymbolicHotKeyEnabled",
                "SLSSetSymbolicHotKeyEnabled",
            ] {
                if let symbol = dlsym(handle, name) {
                    setSymbolicHotKeyEnabled = unsafeBitCast(
                        symbol,
                        to: SetSymbolicHotKeyEnabled.self
                    )
                    trace("SYMBOLIC-HOTKEY set-symbol=\(name)")
                    break
                }
            }
        }

        for handle in dynamicLibraryHandles where isSymbolicHotKeyEnabled == nil {
            for name in [
                "CGSIsSymbolicHotKeyEnabled",
                "SLSIsSymbolicHotKeyEnabled",
            ] {
                if let symbol = dlsym(handle, name) {
                    isSymbolicHotKeyEnabled = unsafeBitCast(
                        symbol,
                        to: IsSymbolicHotKeyEnabled.self
                    )
                    trace("SYMBOLIC-HOTKEY is-symbol=\(name)")
                    break
                }
            }
        }

        guard let isSymbolicHotKeyEnabled else {
            trace("SYMBOLIC-HOTKEY unavailable reason=no-state-query")
            return
        }
        spotlightWasEnabled = isSymbolicHotKeyEnabled(spotlightSearchHotKeyID)
        trace(
            "SYMBOLIC-HOTKEY initial id=\(spotlightSearchHotKeyID) enabled=\(spotlightWasEnabled == true ? 1 : 0)"
        )
    }

    private func suppressSpotlight(reason: String) {
        guard !spotlightSuppressed else { return }
        guard spotlightWasEnabled != nil else {
            trace("SYMBOLIC-HOTKEY suppress=failed reason=\(reason) state-unknown=1")
            return
        }
        if spotlightWasEnabled == false {
            trace("SYMBOLIC-HOTKEY suppress=unnecessary reason=\(reason) initial-enabled=0")
            registerCarbonHotKey(reason: reason)
            return
        }
        guard let setSymbolicHotKeyEnabled, let isSymbolicHotKeyEnabled else {
            trace("SYMBOLIC-HOTKEY suppress=failed reason=\(reason) api-unavailable=1")
            return
        }

        let result = setSymbolicHotKeyEnabled(spotlightSearchHotKeyID, false)
        let enabledAfter = isSymbolicHotKeyEnabled(spotlightSearchHotKeyID)
        spotlightSuppressed = result == 0 && !enabledAfter
        trace(
            "SYMBOLIC-HOTKEY suppress=\(spotlightSuppressed ? "ok" : "failed") reason=\(reason) result=\(result) enabled-after=\(enabledAfter ? 1 : 0)"
        )
        if spotlightSuppressed {
            registerCarbonHotKey(reason: reason)
        }
    }

    private func restoreSpotlight(reason: String) {
        unregisterCarbonHotKey(reason: reason)
        guard spotlightSuppressed else { return }
        guard let setSymbolicHotKeyEnabled, let isSymbolicHotKeyEnabled else {
            trace("SYMBOLIC-HOTKEY restore=failed reason=\(reason) api-unavailable=1")
            return
        }

        let result = setSymbolicHotKeyEnabled(spotlightSearchHotKeyID, true)
        let enabledAfter = isSymbolicHotKeyEnabled(spotlightSearchHotKeyID)
        if result == 0 && enabledAfter {
            spotlightSuppressed = false
        }
        trace(
            "SYMBOLIC-HOTKEY restore=\(!spotlightSuppressed ? "ok" : "failed") reason=\(reason) result=\(result) enabled-after=\(enabledAfter ? 1 : 0)"
        )
    }

    private func installCarbonEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotKeyCallback,
            1,
            &eventType,
            context,
            &carbonEventHandler
        )
        trace("CARBON handler-install result=\(result)")
    }

    private func registerCarbonHotKey(reason: String) {
        guard carbonHotKey == nil else { return }
        let result = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(cmdKey),
            carbonHotKeyIdentifier,
            GetApplicationEventTarget(),
            0,
            &carbonHotKey
        )
        trace(
            "CARBON register-command-space result=\(result) reason=\(reason)"
        )
    }

    private func unregisterCarbonHotKey(reason: String) {
        guard let carbonHotKey else { return }
        let result = UnregisterEventHotKey(carbonHotKey)
        self.carbonHotKey = nil
        trace(
            "CARBON unregister-command-space result=\(result) reason=\(reason)"
        )
    }

    fileprivate func handleCarbonCommandSpace() {
        guard NSApp.isActive, window.isKeyWindow else {
            trace(
                "CARBON command-space ignored active=\(NSApp.isActive ? 1 : 0) key-window=\(window.isKeyWindow ? 1 : 0)"
            )
            return
        }
        commandDownWithoutSpace = false
        trace("RESULT captured-command-space-via-carbon")
        show(
            "WE DID IT",
            detail: "Carbon received ⌘Space after Spotlight was disabled. The raw Space event remains unavailable."
        )
        NSLog("WE DID IT: captured Command-Space via Carbon")
    }

    fileprivate func handle(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            trace("TAP disabled type=\(type.rawValue); re-enabling")
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            show("Tap re-enabled", detail: "Press ⌘Space again.")
            return retainedEvent(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let commandIsDown = event.flags.contains(.maskCommand)
        let active = NSApp.isActive
        let keyWindow = window.isKeyWindow

        if keyCode == spaceKeyCode ||
           keyCode == leftCommandKeyCode || keyCode == rightCommandKeyCode {
            trace(
                "EVENT type=\(type.rawValue) keycode=\(keyCode) command=\(commandIsDown ? 1 : 0) active=\(active ? 1 : 0) key-window=\(keyWindow ? 1 : 0)"
            )
        }

        if type == .flagsChanged,
           keyCode == leftCommandKeyCode || keyCode == rightCommandKeyCode {
            if commandIsDown, active, keyWindow {
                commandDownWithoutSpace = true
                trace("STATE command-down-awaiting-space")
                show(
                    "Command reached the tap",
                    detail: "Waiting to see whether macOS also delivers Space…"
                )
            } else if !commandIsDown, commandDownWithoutSpace {
                commandDownWithoutSpace = false
                trace("RESULT command-arrived-space-missing")
                show(
                    "Command arrived; Space did not",
                    detail: "Spotlight claimed Space before this HID event-tap callback could observe it."
                )
            }
            return retainedEvent(event)
        }

        if keyCode == spaceKeyCode,
           type == .keyDown,
           commandIsDown,
           active,
           keyWindow {
            commandDownWithoutSpace = false
            swallowingSpace = true
            show(
                "WE DID IT",
                detail: "The app captured ⌘Space before Spotlight."
            )
            trace("RESULT captured-command-space")
            NSLog("WE DID IT: captured Command-Space")
            return nil
        }

        if keyCode == spaceKeyCode, type == .keyUp, swallowingSpace {
            swallowingSpace = false
            return nil
        }

        return retainedEvent(event)
    }

    private func show(_ headline: String, detail detailText: String) {
        status.stringValue = headline
        detail.stringValue = detailText
    }

    private func openTrace() {
        if !FileManager.default.fileExists(atPath: tracePath) {
            FileManager.default.createFile(atPath: tracePath, contents: nil)
        }
        traceFile = FileHandle(forWritingAtPath: tracePath)
        _ = try? traceFile?.seekToEnd()
    }

    private func trace(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(timestamp) \(message)\n".data(using: .utf8) else { return }
        traceFile?.write(data)
        try? traceFile?.synchronize()
    }
}

private let application = NSApplication.shared
private let delegate = CommandSpaceProbe()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
