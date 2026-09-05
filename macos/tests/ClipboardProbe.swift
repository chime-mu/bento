import AppKit
import Foundation

private enum ProbeError: LocalizedError {
    case usage
    case noSupportedContent
    case kindMismatch(expected: ClipboardKind, actual: ClipboardKind)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "usage: ClipboardProbe snapshot | save <directory> | restore <directory> | clear | set-text <file> | set-png <file> | write <text|png> <file>"
        case .noSupportedContent:
            return "the pasteboard has no supported text or PNG content"
        case .kindMismatch(let expected, let actual):
            return "expected \(expected.rawValue), found \(actual.rawValue)"
        }
    }
}

@main
private struct ClipboardProbe {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else { throw ProbeError.usage }

        switch (command, arguments.count) {
        case ("snapshot", 1):
            guard let content = try MacPasteboard.read() else {
                throw ProbeError.noSupportedContent
            }
            report(content)

        case ("save", 2):
            guard let content = try MacPasteboard.read() else {
                throw ProbeError.noSupportedContent
            }
            let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try Data(content.kind.rawValue.utf8).write(
                to: directory.appendingPathComponent("kind"),
                options: .atomic
            )
            try content.data.write(
                to: directory.appendingPathComponent("content"),
                options: .atomic
            )
            report(content)

        case ("restore", 2):
            let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
            let kindData = try Data(contentsOf: directory.appendingPathComponent("kind"))
            guard let rawKind = String(data: kindData, encoding: .utf8),
                  let kind = ClipboardKind(rawValue: rawKind) else {
                throw ProbeError.usage
            }
            let data = try Data(contentsOf: directory.appendingPathComponent("content"))
            let content = try ClipboardContent(kind: kind, data: data)
            try MacPasteboard.write(content)
            report(content)

        case ("clear", 1):
            NSPasteboard.general.clearContents()
            print("empty")

        case ("set-text", 2):
            try set(kind: .text, from: arguments[1])

        case ("set-png", 2):
            try set(kind: .png, from: arguments[1])

        case ("write", 3):
            guard let expectedKind = ClipboardKind(rawValue: arguments[1]),
                  let content = try MacPasteboard.read() else {
                throw ProbeError.noSupportedContent
            }
            guard content.kind == expectedKind else {
                throw ProbeError.kindMismatch(expected: expectedKind, actual: content.kind)
            }
            try content.data.write(to: URL(fileURLWithPath: arguments[2]), options: .atomic)
            report(content)

        default:
            throw ProbeError.usage
        }
    }

    private static func set(kind: ClipboardKind, from path: String) throws {
        let content = try ClipboardContent(
            kind: kind,
            data: Data(contentsOf: URL(fileURLWithPath: path))
        )
        try MacPasteboard.write(content)
        report(content)
    }

    private static func report(_ content: ClipboardContent) {
        print("\(content.kind.rawValue) \(content.fingerprint) \(content.data.count)")
    }
}
