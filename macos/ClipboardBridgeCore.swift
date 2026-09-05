import AppKit
import CryptoKit
import Foundation

let bentoClipboardVersion = 1
let bentoClipboardPayloadLimit = 16 * 1024 * 1024
let bentoClipboardLineLimit = ((bentoClipboardPayloadLimit + 2) / 3) * 4 + 4096

enum ClipboardProtocolError: LocalizedError, Equatable {
    case malformed
    case unsupportedVersion
    case unsupportedKind
    case invalidBase64
    case invalidText
    case oversized
    case fingerprintMismatch

    var errorDescription: String? {
        switch self {
        case .malformed: return "Malformed clipboard message"
        case .unsupportedVersion: return "Unsupported clipboard protocol version"
        case .unsupportedKind: return "Unsupported clipboard content kind"
        case .invalidBase64: return "Invalid clipboard base64 data"
        case .invalidText: return "Clipboard text is not UTF-8"
        case .oversized: return "Clipboard payload exceeds 16 MiB"
        case .fingerprintMismatch: return "Clipboard fingerprint does not match its content"
        }
    }
}

enum ClipboardKind: String {
    case text
    case png
}

struct ClipboardContent: Equatable {
    let kind: ClipboardKind
    let data: Data

    init(kind: ClipboardKind, data: Data) throws {
        guard data.count <= bentoClipboardPayloadLimit else {
            throw ClipboardProtocolError.oversized
        }
        if kind == .text, String(data: data, encoding: .utf8) == nil {
            throw ClipboardProtocolError.invalidText
        }
        self.kind = kind
        self.data = data
    }

    var fingerprint: String {
        var material = Data(kind.rawValue.utf8)
        material.append(0)
        material.append(data)
        return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }
}

enum ClipboardEvent: Equatable {
    case sync
    case clipboard(ClipboardContent)

    func encodedLine() throws -> Data {
        let object: [String: Any]
        switch self {
        case .sync:
            object = ["version": bentoClipboardVersion, "type": "sync"]
        case .clipboard(let content):
            object = [
                "version": bentoClipboardVersion,
                "type": "clipboard",
                "kind": content.kind.rawValue,
                "data": content.data.base64EncodedString(),
                "sha256": content.fingerprint,
            ]
        }
        var encoded = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        encoded.append(0x0a)
        return encoded
    }

    static func decode(line: Data) throws -> ClipboardEvent {
        guard line.count <= bentoClipboardLineLimit,
              let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
              let version = object["version"] as? Int,
              let type = object["type"] as? String else {
            throw ClipboardProtocolError.malformed
        }
        guard version == bentoClipboardVersion else {
            throw ClipboardProtocolError.unsupportedVersion
        }
        if type == "sync" { return .sync }
        guard type == "clipboard",
              let rawKind = object["kind"] as? String,
              let kind = ClipboardKind(rawValue: rawKind),
              let encoded = object["data"] as? String,
              let expectedFingerprint = object["sha256"] as? String else {
            throw type == "clipboard" ? ClipboardProtocolError.unsupportedKind : .malformed
        }
        // Reject before allocating decoded storage. Four base64 bytes carry at most three
        // decoded bytes; the small allowance covers terminal padding.
        guard encoded.utf8.count <= ((bentoClipboardPayloadLimit + 2) / 3) * 4 else {
            throw ClipboardProtocolError.oversized
        }
        guard let data = Data(base64Encoded: encoded, options: []) else {
            throw ClipboardProtocolError.invalidBase64
        }
        let content = try ClipboardContent(kind: kind, data: data)
        guard content.fingerprint == expectedFingerprint else {
            throw ClipboardProtocolError.fingerprintMismatch
        }
        return .clipboard(content)
    }
}

struct NDJSONFramer {
    private(set) var buffer = Data()

    mutating func append(_ fragment: Data) throws -> [Data] {
        buffer.append(fragment)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0a) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line.count > bentoClipboardLineLimit { throw ClipboardProtocolError.oversized }
            if !line.isEmpty { lines.append(line) }
        }
        if buffer.count > bentoClipboardLineLimit { throw ClipboardProtocolError.oversized }
        return lines
    }
}

struct ClipboardEchoSuppressor {
    private(set) var lastSent: String?
    private(set) var lastApplied: String?

    mutating func recordSent(_ fingerprint: String) {
        lastSent = fingerprint
    }

    mutating func shouldSendLocal(_ fingerprint: String) -> Bool {
        if let applied = lastApplied {
            lastApplied = nil
            if fingerprint == applied {
                lastSent = fingerprint
                return false
            }

            // A different pasteboard value after applying remote content is a real
            // local change, even when it happens to match something sent earlier.
            lastSent = fingerprint
            return true
        }
        if fingerprint == lastSent { return false }
        lastSent = fingerprint
        return true
    }

    mutating func shouldApplyRemote(_ fingerprint: String) -> Bool {
        if fingerprint == lastSent || fingerprint == lastApplied { return false }
        lastApplied = fingerprint
        return true
    }
}

enum MacPasteboard {
    static func preferredContent(
        text: String?,
        png: Data?,
        bitmapData: Data?
    ) throws -> ClipboardContent? {
        // A clipboard can advertise both representations. Text is intentionally first.
        if let text {
            return try ClipboardContent(kind: .text, data: Data(text.utf8))
        }
        if let png {
            return try ClipboardContent(kind: .png, data: png)
        }
        guard let bitmapData,
              let bitmap = NSBitmapImageRep(data: bitmapData),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        return try ClipboardContent(kind: .png, data: png)
    }

    static func read(_ pasteboard: NSPasteboard = .general) throws -> ClipboardContent? {
        let imageData = pasteboard.data(forType: .tiff)
            ?? NSImage(pasteboard: pasteboard)?.tiffRepresentation
        return try preferredContent(
            text: pasteboard.string(forType: .string),
            png: pasteboard.data(forType: .png),
            bitmapData: imageData
        )
    }

    static func write(_ content: ClipboardContent, to pasteboard: NSPasteboard = .general) throws {
        pasteboard.clearContents()
        switch content.kind {
        case .text:
            guard let value = String(data: content.data, encoding: .utf8) else {
                throw ClipboardProtocolError.invalidText
            }
            pasteboard.setString(value, forType: .string)
        case .png:
            pasteboard.setData(content.data, forType: .png)
        }
    }
}
