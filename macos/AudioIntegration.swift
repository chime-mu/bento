import Darwin
import Foundation

// Shared error type for private QMP and virtio-serial control channels.
enum BentoIntegrationError: LocalizedError, Equatable {
    case io(String)

    var errorDescription: String? {
        switch self { case .io(let detail): return "I/O failure: \(detail)" }
    }
}

/// Kernel-backed process identity closes the PID-reuse gap before a native
/// bridge accepts a QEMU-created socket.
struct KernelProcessIdentity: Equatable {
    let processIdentifier: pid_t
    let executablePath: String
    let startSeconds: UInt64
    let startMicroseconds: UInt64

    var isQEMUSystemProcess: Bool {
        let name = URL(fileURLWithPath: executablePath).lastPathComponent
        if name == "BentoQEMU" { return true }
        guard name.hasPrefix("qemu-system-") else { return false }
        let architecture = name.dropFirst("qemu-system-".count)
        return !architecture.isEmpty && architecture.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || "_+-".contains($0))
        }
    }

    static func capture(processIdentifier: pid_t) -> KernelProcessIdentity? {
        guard processIdentifier > 1 else { return nil }
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(processIdentifier, &pathBuffer, UInt32(pathBuffer.count)) > 0 else {
            return nil
        }
        var information = proc_bsdinfo()
        let informationSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let bytes = withUnsafeMutablePointer(to: &information) {
            proc_pidinfo(processIdentifier, PROC_PIDTBSDINFO, 0, $0, informationSize)
        }
        guard bytes == informationSize else { return nil }
        return KernelProcessIdentity(
            processIdentifier: processIdentifier,
            executablePath: String(cString: pathBuffer),
            startSeconds: information.pbi_start_tvsec,
            startMicroseconds: information.pbi_start_tvusec
        )
    }
}

import AudioToolbox
import CoreAudio
import Foundation

enum HostAudioDirection: String, CaseIterable, Equatable {
    case output
    case input
}

struct HostAudioDevice: Equatable {
    let uid: String
    let displayName: String
    let sdlName: String
}

/// A direction-aware description of one CoreAudio device. Keeping this small
/// value separate from the platform enumerator makes SDL-compatible naming
/// deterministic and testable without depending on the test Mac's hardware.
struct HostAudioHardwareDescriptor: Equatable {
    let uid: String
    let outputName: String?
    let inputName: String?
}

struct HostAudioDeviceCatalog: Equatable {
    let outputDevices: [HostAudioDevice]
    let inputDevices: [HostAudioDevice]

    static let empty = Self(outputDevices: [], inputDevices: [])

    static func make(from descriptors: [HostAudioHardwareDescriptor]) -> Self {
        Self(
            outputDevices: makeDevices(from: descriptors, direction: .output),
            inputDevices: makeDevices(from: descriptors, direction: .input)
        )
    }

    func devices(for direction: HostAudioDirection) -> [HostAudioDevice] {
        switch direction {
        case .output: outputDevices
        case .input: inputDevices
        }
    }

    func device(uid: String, direction: HostAudioDirection) -> HostAudioDevice? {
        devices(for: direction).first { $0.uid == uid }
    }

    private static func makeDevices(
        from descriptors: [HostAudioHardwareDescriptor],
        direction: HostAudioDirection
    ) -> [HostAudioDevice] {
        var occurrences: [String: Int] = [:]
        var devices: [HostAudioDevice] = []

        for descriptor in descriptors {
            let rawName: String?
            switch direction {
            case .output: rawName = descriptor.outputName
            case .input: rawName = descriptor.inputName
            }
            guard let rawName else { continue }

            // SDL's CoreAudio enumerator trims trailing ASCII spaces, then its
            // generic device list adds a numeric suffix to duplicate names.
            // QEMU must receive that exact SDL-facing name, while preferences
            // retain the stable CoreAudio UID.
            let displayName = rawName.trimmingTrailingASCIISpaces()
            guard !displayName.isEmpty else { continue }
            let occurrence = occurrences[displayName, default: 0] + 1
            occurrences[displayName] = occurrence
            let sdlName = occurrence == 1
                ? displayName
                : "\(displayName) (\(occurrence))"
            devices.append(HostAudioDevice(
                uid: descriptor.uid,
                displayName: displayName,
                sdlName: sdlName
            ))
        }

        return devices.sorted {
            let comparison = $0.sdlName.localizedStandardCompare($1.sdlName)
            if comparison == .orderedSame { return $0.uid < $1.uid }
            return comparison == .orderedAscending
        }
    }
}

private extension String {
    func trimmingTrailingASCIISpaces() -> String {
        var result = self
        while result.last == " " { result.removeLast() }
        return result
    }
}

protocol HostAudioDeviceProviding {
    func catalog() -> HostAudioDeviceCatalog
}

struct CoreAudioHostAudioDeviceProvider: HostAudioDeviceProviding {
    func catalog() -> HostAudioDeviceCatalog {
        let descriptors: [HostAudioHardwareDescriptor] = audioDeviceIdentifiers().compactMap { deviceID in
            guard let uid = stringProperty(
                deviceID: deviceID,
                selector: kAudioDevicePropertyDeviceUID,
                scope: kAudioObjectPropertyScopeGlobal
            ), !uid.isEmpty else { return nil }

            let outputName = directionName(
                deviceID: deviceID,
                scope: kAudioDevicePropertyScopeOutput
            )
            let inputName = directionName(
                deviceID: deviceID,
                scope: kAudioDevicePropertyScopeInput
            )
            guard outputName != nil || inputName != nil else { return nil }
            return HostAudioHardwareDescriptor(
                uid: uid,
                outputName: outputName,
                inputName: inputName
            )
        }
        return .make(from: descriptors)
    }

    private func audioDeviceIdentifiers() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr,
        size > 0,
        size.isMultiple(of: UInt32(MemoryLayout<AudioDeviceID>.size)) else {
            return []
        }

        var identifiers = [AudioDeviceID](
            repeating: 0,
            count: Int(size) / MemoryLayout<AudioDeviceID>.size
        )
        let status = identifiers.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size,
                buffer.baseAddress!
            )
        }
        return status == noErr ? identifiers : []
    }

    private func directionName(
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> String? {
        guard channelCount(deviceID: deviceID, scope: scope) > 0 else { return nil }
        return stringProperty(
            deviceID: deviceID,
            selector: kAudioObjectPropertyName,
            scope: scope
        )
    }

    private func channelCount(
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &size
        ) == noErr,
        size >= UInt32(MemoryLayout<AudioBufferList>.size) else {
            return 0
        }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            storage
        ) == noErr else {
            return 0
        }

        let buffers = UnsafeMutableAudioBufferListPointer(
            storage.assumingMemoryBound(to: AudioBufferList.self)
        )
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func stringProperty(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &size,
                pointer
            )
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}

enum AudioRouteSelection: Equatable {
    case systemDefault
    case device(uid: String, lastKnownName: String)

    var deviceUID: String? {
        guard case .device(let uid, _) = self else { return nil }
        return uid
    }

    var lastKnownName: String? {
        guard case .device(_, let name) = self else { return nil }
        return name
    }
}

struct AudioRoutingPreferences: Equatable {
    var output: AudioRouteSelection
    var input: AudioRouteSelection

    static let systemDefaults = Self(output: .systemDefault, input: .systemDefault)

    subscript(direction: HostAudioDirection) -> AudioRouteSelection {
        get {
            switch direction {
            case .output: output
            case .input: input
            }
        }
        set {
            switch direction {
            case .output: output = newValue
            case .input: input = newValue
            }
        }
    }
}

struct AudioRoutingPreferenceStore {
    static let key = "audioRoutingPreferences"
    static let schemaVersion = 1

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AudioRoutingPreferences {
        guard let data = defaults.data(forKey: Self.key),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.schemaVersion == Self.schemaVersion,
              let output = payload.output.selection,
              let input = payload.input.selection else {
            return .systemDefaults
        }
        return AudioRoutingPreferences(output: output, input: input)
    }

    func save(_ preferences: AudioRoutingPreferences) {
        let payload = Payload(
            schemaVersion: Self.schemaVersion,
            output: RoutePayload(preferences.output),
            input: RoutePayload(preferences.input)
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        // Both directions and the schema travel in one UserDefaults value, so
        // readers never observe a half-updated speaker/microphone pair.
        defaults.set(data, forKey: Self.key)
    }

    func set(_ selection: AudioRouteSelection, for direction: HostAudioDirection) {
        var preferences = load()
        preferences[direction] = selection
        save(preferences)
    }

    private struct Payload: Codable {
        let schemaVersion: Int
        let output: RoutePayload
        let input: RoutePayload
    }

    private struct RoutePayload: Codable {
        enum Kind: String, Codable {
            case systemDefault
            case device
        }

        let kind: Kind
        let uid: String?
        let lastKnownName: String?

        init(_ selection: AudioRouteSelection) {
            switch selection {
            case .systemDefault:
                kind = .systemDefault
                uid = nil
                lastKnownName = nil
            case .device(let uid, let lastKnownName):
                kind = .device
                self.uid = uid
                self.lastKnownName = lastKnownName
            }
        }

        var selection: AudioRouteSelection? {
            switch kind {
            case .systemDefault:
                guard uid == nil, lastKnownName == nil else { return nil }
                return .systemDefault
            case .device:
                guard let uid, !uid.isEmpty,
                      let lastKnownName, !lastKnownName.isEmpty else { return nil }
                return .device(uid: uid, lastKnownName: lastKnownName)
            }
        }
    }
}

struct ResolvedAudioRoutes: Equatable {
    let outputSDLName: String?
    let inputSDLName: String?
}

struct AudioLaunchConfiguration: Equatable {
    static let inheritedSDLDeviceNameKey = "SDL_AUDIO_DEVICE_NAME"
    static let outputDeviceNameKey = "BENTO_SDL_OUTPUT_DEVICE_NAME"
    static let inputDeviceNameKey = "BENTO_SDL_INPUT_DEVICE_NAME"

    let routes: ResolvedAudioRoutes
    let environment: [String: String]

    static func make(
        baseEnvironment: [String: String],
        preferences: AudioRoutingPreferences,
        catalog: HostAudioDeviceCatalog
    ) -> Self {
        let routes = ResolvedAudioRoutes(
            outputSDLName: resolve(
                preferences.output,
                direction: .output,
                catalog: catalog
            ),
            inputSDLName: resolve(
                preferences.input,
                direction: .input,
                catalog: catalog
            )
        )
        var environment = baseEnvironment
        environment.removeValue(forKey: inheritedSDLDeviceNameKey)
        environment.removeValue(forKey: outputDeviceNameKey)
        environment.removeValue(forKey: inputDeviceNameKey)
        if let outputSDLName = routes.outputSDLName {
            environment[outputDeviceNameKey] = outputSDLName
        }
        if let inputSDLName = routes.inputSDLName {
            environment[inputDeviceNameKey] = inputSDLName
        }
        return Self(routes: routes, environment: environment)
    }

    private static func resolve(
        _ selection: AudioRouteSelection,
        direction: HostAudioDirection,
        catalog: HostAudioDeviceCatalog
    ) -> String? {
        guard case .device(let uid, _) = selection else { return nil }
        return catalog.device(uid: uid, direction: direction)?.sdlName
    }
}

import Darwin
import Foundation

/// Connects the helper to one of QEMU's private virtio-serial chardev sockets.
/// The socket must already exist inside the launcher's owned, mode-0700 run
/// directory so another local user cannot pre-create or swap the endpoint.
enum NativeBridgeSocket {
    static func connectSecure(path: String, label: String) throws -> Int32 {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw BentoIntegrationError.io("\(label) socket path must be an absolute pathname")
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.path == path else {
            throw BentoIntegrationError.io("\(label) socket path must already be standardized")
        }
        let parent = url.deletingLastPathComponent()
        var parentInfo = stat()
        var socketInfo = stat()
        guard lstat(parent.path, &parentInfo) == 0,
              (parentInfo.st_mode & S_IFMT) == S_IFDIR,
              parentInfo.st_uid == getuid(),
              (parentInfo.st_mode & 0o077) == 0,
              lstat(path, &socketInfo) == 0,
              (socketInfo.st_mode & S_IFMT) == S_IFSOCK,
              socketInfo.st_uid == getuid() else {
            throw BentoIntegrationError.io("\(label) endpoint must be a private owned Unix socket")
        }

        let pathBytes = Array(path.utf8)
        var address = sockaddr_un()
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw BentoIntegrationError.io("\(label) socket path is too long")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            buffer.copyBytes(from: pathBytes)
        }
        let socketDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { throw BentoIntegrationError.io("cannot create \(label) socket") }
        var noSignal: Int32 = 1
        guard withUnsafePointer(to: &noSignal, {
            setsockopt(socketDescriptor, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }) == 0 else {
            Darwin.close(socketDescriptor)
            throw BentoIntegrationError.io("cannot configure \(label) socket")
        }
        let offset = MemoryLayout.offset(of: \sockaddr_un.sun_path) ?? 0
        let length = socklen_t(offset + pathBytes.count + 1)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socketDescriptor, $0, length)
            }
        }
        guard result == 0 else {
            let detail = String(cString: strerror(errno))
            Darwin.close(socketDescriptor)
            throw BentoIntegrationError.io("cannot connect to \(label) socket: \(detail)")
        }
        return socketDescriptor
    }

    /// Writes every byte, retrying on EINTR, or throws.
    static func writeAll(_ data: Data, to descriptor: Int32, label: String) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    throw BentoIntegrationError.io("cannot write the guest \(label) channel")
                }
            }
        }
    }
}

import CoreAudio
import Darwin
import Foundation

struct NativeAudioRouteRequest: Equatable {
    let direction: HostAudioDirection
    let deviceUID: String?

    static func decode(_ data: Data) -> Self? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.keys.sorted() == ["deviceUID", "direction", "type"],
              object["type"] as? String == "select",
              let rawDirection = object["direction"] as? String,
              let direction = HostAudioDirection(rawValue: rawDirection) else {
            return nil
        }
        let rawUID = object["deviceUID"]
        if rawUID is NSNull {
            return Self(direction: direction, deviceUID: nil)
        }
        guard let deviceUID = rawUID as? String, !deviceUID.isEmpty else { return nil }
        return Self(direction: direction, deviceUID: deviceUID)
    }
}

struct NativeAudioCatalogMessage {
    static func encode(
        catalog: HostAudioDeviceCatalog,
        preferences: AudioRoutingPreferences
    ) throws -> Data {
        func records(_ devices: [HostAudioDevice]) -> [[String: String]] {
            devices.map { ["deviceUID": $0.uid, "name": $0.sdlName] }
        }

        let object: [String: Any] = [
            "type": "catalog",
            "outputs": records(catalog.outputDevices),
            "inputs": records(catalog.inputDevices),
            "selectedOutputUID": preferences.output.deviceUID as Any? ?? NSNull(),
            "selectedInputUID": preferences.input.deviceUID as Any? ?? NSNull(),
        ]
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }
}

/// Atomically publishes the selected SDL endpoint to the patched QEMU audio
/// backend. `default` is deliberately not valid canonical base64, so arbitrary
/// CoreAudio names cannot collide with the sentinel.
struct NativeAudioRouteFileStore {
    private let directory: URL

    init(directoryPath: String) throws {
        guard directoryPath.hasPrefix("/"), !directoryPath.utf8.contains(0) else {
            throw BentoIntegrationError.io("audio route directory must be an absolute pathname")
        }
        let url = URL(fileURLWithPath: directoryPath).standardizedFileURL
        guard url.path == directoryPath else {
            throw BentoIntegrationError.io("audio route directory must already be standardized")
        }
        var information = stat()
        guard lstat(directoryPath, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFDIR,
              information.st_uid == getuid(),
              (information.st_mode & 0o077) == 0 else {
            throw BentoIntegrationError.io("audio route directory must be private and owned by this user")
        }
        directory = url
    }

    func publish(_ sdlName: String?, for direction: HostAudioDirection) throws {
        let payload = sdlName.map { Data($0.utf8).base64EncodedString() } ?? "default"
        let destination = directory.appendingPathComponent(direction.rawValue, isDirectory: false)
        let temporary = directory.appendingPathComponent(
            ".\(direction.rawValue).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let descriptor = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw BentoIntegrationError.io("cannot create the audio route update")
        }
        do {
            let bytes = Array((payload + "\n").utf8)
            try bytes.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                    if count > 0 {
                        offset += count
                    } else if count < 0 && errno == EINTR {
                        continue
                    } else {
                        throw BentoIntegrationError.io("cannot write the audio route update")
                    }
                }
            }
            guard fsync(descriptor) == 0 else {
                throw BentoIntegrationError.io("cannot flush the audio route update")
            }
        } catch {
            Darwin.close(descriptor)
            unlink(temporary.path)
            throw error
        }
        Darwin.close(descriptor)
        guard rename(temporary.path, destination.path) == 0 else {
            unlink(temporary.path)
            throw BentoIntegrationError.io("cannot publish the audio route update")
        }
    }
}

final class CoreAudioDeviceChangeMonitor {
    private let queue = DispatchQueue(label: "dev.bento.native.audio-devices")
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init(onChange: @escaping () -> Void) throws {
        for selector in [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDefaultInputDevice,
        ] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let listener: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                queue,
                listener
            )
            guard status == noErr else {
                removeListeners()
                throw BentoIntegrationError.io("cannot monitor CoreAudio device changes (status \(status))")
            }
            listeners.append((address, listener))
        }
    }

    deinit {
        removeListeners()
    }

    private func removeListeners() {
        for (storedAddress, listener) in listeners {
            var address = storedAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                queue,
                listener
            )
        }
        listeners.removeAll()
    }
}

final class NativeAudioBridge {
    private let descriptor: Int32
    private let deviceProvider: HostAudioDeviceProviding
    private let preferenceStore: AudioRoutingPreferenceStore
    private let routeStore: NativeAudioRouteFileStore
    private let stateQueue = DispatchQueue(label: "dev.bento.native.audio-bridge-state")
    private let writeQueue = DispatchQueue(label: "dev.bento.native.audio-bridge-writes")
    private let stopLock = NSLock()
    private var monitor: CoreAudioDeviceChangeMonitor?
    private var stopped = false

    init(
        targetPID: pid_t,
        socketPath: String,
        routeDirectoryPath: String,
        deviceProvider: HostAudioDeviceProviding = CoreAudioHostAudioDeviceProvider(),
        preferenceStore: AudioRoutingPreferenceStore = AudioRoutingPreferenceStore()
    ) throws {
        guard let processIdentity = KernelProcessIdentity.capture(processIdentifier: targetPID),
              processIdentity.isQEMUSystemProcess else {
            throw BentoIntegrationError.io("native audio bridge target is not a QEMU system process")
        }
        descriptor = try NativeBridgeSocket.connectSecure(path: socketPath, label: "audio bridge")
        self.deviceProvider = deviceProvider
        self.preferenceStore = preferenceStore
        routeStore = try NativeAudioRouteFileStore(directoryPath: routeDirectoryPath)
        monitor = try CoreAudioDeviceChangeMonitor { [weak self] in
            self?.catalogDidChange()
        }
    }

    deinit {
        stop()
    }

    func run() throws {
        try publishEffectiveRoutesAndCatalog()
        var line = Data()
        while true {
            var byte: UInt8 = 0
            let count = Darwin.read(descriptor, &byte, 1)
            if count == 1 {
                if byte == 0x0A {
                    try handle(line)
                    line.removeAll(keepingCapacity: true)
                } else if byte != 0x0D {
                    guard line.count < 65_536 else {
                        throw BentoIntegrationError.io("guest audio request exceeds 64 KiB")
                    }
                    line.append(byte)
                }
            } else if count == 0 {
                return
            } else if errno != EINTR {
                throw BentoIntegrationError.io("cannot read the guest audio channel")
            }
        }
    }

    func stop() {
        stopLock.lock()
        guard !stopped else {
            stopLock.unlock()
            return
        }
        stopped = true
        stopLock.unlock()
        monitor = nil
        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
    }

    private func handle(_ data: Data) throws {
        try stateQueue.sync {
            try handleSerialized(data)
        }
    }

    private func handleSerialized(_ data: Data) throws {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object.keys.sorted() == ["type"],
           object["type"] as? String == "get-catalog" {
            try sendCatalog()
            return
        }
        guard let request = NativeAudioRouteRequest.decode(data) else {
            throw BentoIntegrationError.io("guest sent an invalid audio request")
        }

        let catalog = deviceProvider.catalog()
        let selection: AudioRouteSelection
        if let uid = request.deviceUID {
            guard let device = catalog.device(uid: uid, direction: request.direction) else {
                try sendCatalog(catalog: catalog)
                return
            }
            selection = .device(uid: uid, lastKnownName: device.displayName)
        } else {
            selection = .systemDefault
        }
        preferenceStore.set(selection, for: request.direction)
        try publishEffectiveRoutes(catalog: catalog)
        try sendCatalog(catalog: catalog)
    }

    private func catalogDidChange() {
        stateQueue.async { [weak self] in
            guard let self, !self.hasStopped() else { return }
            do {
                try self.publishEffectiveRoutesAndCatalog()
            } catch {
                fputs("[audio-bridge] \(error.localizedDescription)\n", stderr)
                self.stop()
            }
        }
    }

    private func hasStopped() -> Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return stopped
    }

    private func publishEffectiveRoutesAndCatalog() throws {
        let catalog = deviceProvider.catalog()
        try publishEffectiveRoutes(catalog: catalog)
        try sendCatalog(catalog: catalog)
    }

    private func publishEffectiveRoutes(catalog: HostAudioDeviceCatalog) throws {
        let configuration = AudioLaunchConfiguration.make(
            baseEnvironment: [:],
            preferences: preferenceStore.load(),
            catalog: catalog
        )
        try routeStore.publish(configuration.routes.outputSDLName, for: .output)
        try routeStore.publish(configuration.routes.inputSDLName, for: .input)
    }

    private func sendCatalog(catalog: HostAudioDeviceCatalog? = nil) throws {
        let data = try NativeAudioCatalogMessage.encode(
            catalog: catalog ?? deviceProvider.catalog(),
            preferences: preferenceStore.load()
        )
        try writeQueue.sync {
            try NativeBridgeSocket.writeAll(data, to: descriptor, label: "audio")
        }
    }
}
