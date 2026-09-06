import Darwin
import Foundation

enum SharePathError: LocalizedError, Equatable {
    case notAbsolute
    case unavailable
    case notDirectory
    case symbolicLink
    case notOwned
    case unsafeCharacters
    case homeDirectory
    case libraryDirectory
    case systemDirectory
    case volumeRoot

    var errorDescription: String? {
        switch self {
        case .notAbsolute: return "Choose an absolute folder path."
        case .unavailable: return "The selected folder is unavailable."
        case .notDirectory: return "The selection is not a directory."
        case .symbolicLink: return "Folders reached through symbolic links cannot be shared."
        case .notOwned: return "The selected folder must be directly owned by your Mac account."
        case .unsafeCharacters: return "Folder paths containing commas or control characters cannot be shared."
        case .homeDirectory: return "The whole home directory cannot be shared. Choose a folder inside it."
        case .libraryDirectory: return "Your Library folder cannot be shared."
        case .systemDirectory: return "System and temporary directories cannot be shared."
        case .volumeRoot: return "Choose a user-owned folder inside the volume, not the volume itself."
        }
    }
}

enum SharePathValidator {
    private static func isInside(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    static func validate(
        _ selectedURL: URL,
        fileManager: FileManager = .default,
        ownerUID: uid_t = getuid(),
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> URL {
        guard selectedURL.isFileURL, selectedURL.path.hasPrefix("/") else {
            throw SharePathError.notAbsolute
        }
        let rawPath = selectedURL.path
        guard !rawPath.contains(","),
              !rawPath.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw SharePathError.unsafeCharacters
        }

        let absolute = selectedURL.standardizedFileURL
        let canonical = absolute.resolvingSymlinksInPath().standardizedFileURL
        guard absolute.path == canonical.path else { throw SharePathError.symbolicLink }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: canonical.path, isDirectory: &isDirectory) else {
            throw SharePathError.unavailable
        }
        guard isDirectory.boolValue else { throw SharePathError.notDirectory }
        let attributes = try fileManager.attributesOfItem(atPath: canonical.path)
        guard let owner = attributes[.ownerAccountID] as? NSNumber,
              owner.uint32Value == ownerUID else {
            throw SharePathError.notOwned
        }

        let home = homeURL.resolvingSymlinksInPath().standardizedFileURL.path
        if canonical.path == home { throw SharePathError.homeDirectory }
        if isInside(canonical.path, root: home + "/Library") {
            throw SharePathError.libraryDirectory
        }

        let temporary = fileManager.temporaryDirectory
            .resolvingSymlinksInPath().standardizedFileURL.path
        let blockedTrees = [
            "/System", "/Library", "/Applications", "/usr", "/bin", "/sbin",
            "/etc", "/var", "/dev", "/cores", "/opt", "/private", "/tmp", temporary,
        ]
        if canonical.path == "/" || blockedTrees.contains(where: {
            isInside(canonical.path, root: $0)
        }) {
            throw SharePathError.systemDirectory
        }

        let mountedRoots = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: []
        ) ?? []
        if canonical.path == "/Volumes"
            || mountedRoots.contains(where: {
                $0.resolvingSymlinksInPath().standardizedFileURL.path == canonical.path
            }) {
            throw SharePathError.volumeRoot
        }
        return canonical
    }
}

struct ShareSettings {
    static let pathKey = "sharedFolderPath"
    static let enabledKey = "sharedFolderEnabled"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var path: String? {
        guard let value = defaults.string(forKey: Self.pathKey), !value.isEmpty else {
            return nil
        }
        return value
    }

    var enabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    func save(path: String, enabled: Bool) {
        defaults.set(path, forKey: Self.pathKey)
        defaults.set(enabled, forKey: Self.enabledKey)
    }

    func saveEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
    }
}

struct ImmersivePreferences: Equatable {
    let isEnabled: Bool
    static let defaults = ImmersivePreferences(isEnabled: true)
}

/// One schema-versioned value avoids mistaking missing or future fields for a
/// deliberate opt-out. Invalid values are read as the safe legacy default and
/// deliberately left untouched for a newer Bento version to recover.
struct ImmersivePreferenceStore {
    static let key = "immersivePreferences"
    static let schemaVersion = 1
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> ImmersivePreferences {
        guard let data = defaults.data(forKey: Self.key),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.schemaVersion == Self.schemaVersion else {
            return .defaults
        }
        return ImmersivePreferences(isEnabled: payload.isEnabled)
    }

    func save(_ value: ImmersivePreferences) {
        guard let data = try? JSONEncoder().encode(Payload(
            schemaVersion: Self.schemaVersion,
            isEnabled: value.isEnabled
        )) else { return }
        defaults.set(data, forKey: Self.key)
    }

    private struct Payload: Codable {
        let schemaVersion: Int
        let isEnabled: Bool
    }
}

enum MicrophoneAuthorizationState: Equatable {
    case authorized
    case notDetermined
    case denied
    case restricted
}

enum MicrophonePresentationAction: Equatable {
    case request
    case openSettings
}

struct MicrophonePresentation: Equatable {
    let detail: String
    let granted: Bool
    let actionTitle: String?
    let action: MicrophonePresentationAction?

    static func make(
        state: MicrophoneAuthorizationState,
        requestInFlight: Bool = false
    ) -> MicrophonePresentation {
        switch state {
        case .authorized:
            return .init(
                detail: "Apps in Bento can record from your Mac microphone.",
                granted: true,
                actionTitle: nil,
                action: nil
            )
        case .notDetermined:
            return .init(
                detail: "Optional. Speaker playback works without microphone access.",
                granted: false,
                actionTitle: requestInFlight ? "Waiting…" : "Allow",
                action: .request
            )
        case .denied:
            return .init(
                detail: "Recording is off. Speaker playback will still work.",
                granted: false,
                actionTitle: "Open System Settings",
                action: .openSettings
            )
        case .restricted:
            return .init(
                detail: "Recording is unavailable because of this Mac’s policy.",
                granted: false,
                actionTitle: nil,
                action: nil
            )
        }
    }
}

enum BentoLaunchArgumentPolicy {
    /// Bento.app owns presentation. Direct run-vm.sh callers keep complete
    /// control over the same command-line options.
    static func normalizedForApp(_ source: [String], immersive: Bool) -> [String] {
        let filtered = source.filter { $0 != "--windowed" }
        guard !filtered.contains("--headless"), !immersive else { return filtered }
        return filtered + ["--windowed"]
    }
}

struct RuntimeDescriptor: Decodable {
    let version: Int
    let qmp: String
    let pid: Int32
    let sshPort: Int
    let gpu: String
    let audio: Bool
    let audioSocket: String?
    let audioRoutes: String?

    static func load(from url: URL) throws -> RuntimeDescriptor {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let owner = attributes[.ownerAccountID] as? NSNumber,
              owner.uint32Value == getuid(),
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue == 0o600 else {
            throw CocoaError(.fileReadNoPermission)
        }
        let value = try JSONDecoder().decode(RuntimeDescriptor.self, from: Data(contentsOf: url))
        guard value.version == 2, (1...65535).contains(value.sshPort),
              value.gpu == "virgl" || value.gpu == "software",
              !value.audio || (value.audioSocket != nil && value.audioRoutes != nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return value
    }
}
