import AppKit
import Darwin
import Foundation

private func usage() -> Never {
    fputs("usage: BentoClipboardBridge --socket <unix-socket>\n", stderr)
    exit(64)
}

private func connectUnixSocket(path: String) -> Int32 {
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else { return -1 }
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return -1 }
    var noPipe: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout.size(ofValue: noPipe)))

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let length = UInt8(MemoryLayout<sa_family_t>.size + bytes.count + 1)
    address.sun_len = length
    withUnsafeMutableBytes(of: &address.sun_path) { target in
        target.initializeMemory(as: UInt8.self, repeating: 0)
        target.copyBytes(from: bytes)
    }
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(descriptor, $0, socklen_t(length))
        }
    }
    if result != 0 {
        close(descriptor)
        return -1
    }
    return descriptor
}

private func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
    var offset = 0
    return data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return true }
        while offset < data.count {
            let count = Darwin.send(descriptor, base.advanced(by: offset), data.count - offset, 0)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { return false }
            offset += count
        }
        return true
    }
}

private func runSession(descriptor: Int32, pasteboard: NSPasteboard = .general) {
    var framer = NDJSONFramer()
    var suppressor = ClipboardEchoSuppressor()
    var observedChangeCount = pasteboard.changeCount

    if let local = try? MacPasteboard.read(pasteboard) {
        guard (try? writeAll(ClipboardEvent.clipboard(local).encodedLine(), to: descriptor)) == true else {
            return
        }
        suppressor.recordSent(local.fingerprint)
    }
    guard (try? writeAll(ClipboardEvent.sync.encodedLine(), to: descriptor)) == true else { return }

    while true {
        var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let ready = Darwin.poll(&item, 1, 200)
        if ready < 0 && errno != EINTR { return }
        if ready > 0 && (item.revents & Int16(POLLIN | POLLHUP | POLLERR)) != 0 {
            var bytes = [UInt8](repeating: 0, count: 64 * 1024)
            let count = Darwin.recv(descriptor, &bytes, bytes.count, 0)
            if count <= 0 { return }
            let lines: [Data]
            do {
                lines = try framer.append(Data(bytes.prefix(count)))
            } catch {
                return
            }
            for line in lines {
                guard let event = try? ClipboardEvent.decode(line: line) else { continue }
                switch event {
                case .sync:
                    if let local = try? MacPasteboard.read(pasteboard) {
                        if (try? writeAll(ClipboardEvent.clipboard(local).encodedLine(), to: descriptor)) != true {
                            return
                        }
                        suppressor.recordSent(local.fingerprint)
                    }
                    if (try? writeAll(ClipboardEvent.sync.encodedLine(), to: descriptor)) != true {
                        return
                    }
                case .clipboard(let remote):
                    guard suppressor.shouldApplyRemote(remote.fingerprint) else { continue }
                    do {
                        try MacPasteboard.write(remote, to: pasteboard)
                        observedChangeCount = pasteboard.changeCount
                    } catch {
                        continue
                    }
                }
            }
        }

        if pasteboard.changeCount != observedChangeCount {
            observedChangeCount = pasteboard.changeCount
            guard let local = try? MacPasteboard.read(pasteboard),
                  suppressor.shouldSendLocal(local.fingerprint) else { continue }
            if (try? writeAll(ClipboardEvent.clipboard(local).encodedLine(), to: descriptor)) != true {
                return
            }
        }
    }
}

@main
private enum BentoClipboardBridgeMain {
    static func main() {
        _ = NSApplication.shared
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 2, arguments[0] == "--socket" else { usage() }
        let socketPath = arguments[1]

        // QEMU creates the private listener shortly after it starts. Reconnect forever so
        // session restarts and temporary clipboard failures never take down Bento.
        while true {
            let descriptor = connectUnixSocket(path: socketPath)
            if descriptor < 0 {
                Thread.sleep(forTimeInterval: 0.25)
                continue
            }
            runSession(descriptor: descriptor)
            close(descriptor)
            Thread.sleep(forTimeInterval: 0.25)
        }
    }
}
