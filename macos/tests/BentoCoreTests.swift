import AppKit
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

@main
private enum BentoCoreTests {
    static func main() throws {
        _ = NSApplication.shared
        try testPathValidationAndPersistence()
        try testFramingAndLimits()
        try testPasteboardConversion()
        try testEchoSuppression()
        print("Bento macOS core tests passed")
    }
}
