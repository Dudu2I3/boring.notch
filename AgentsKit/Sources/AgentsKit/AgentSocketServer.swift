import Darwin
import Foundation

/// Listens on a Unix socket. Each connection carries one line; the server reads it, closes the
/// connection right away (so `nc` exits without waiting for its timeout) and hands the line over.
/// One-way by design: nothing is ever written back to the client.
public final class AgentSocketServer: @unchecked Sendable {
    public enum ServerError: Error, Equatable {
        case pathTooLong
        case socket(Int32)
        case bind(Int32)
        case listen(Int32)
    }

    public static let maxLineBytes = 64 * 1024

    private let path: String
    private let onLine: @Sendable (Data) -> Void
    private let queue = DispatchQueue(label: "notch-agents.socket")
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?

    public init(path: String, onLine: @escaping @Sendable (Data) -> Void) {
        self.path = path
        self.onLine = onLine
    }

    public func start() throws {
        var address = sockaddr_un()
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw ServerError.pathTooLong }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }

        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socket(errno) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw ServerError.bind(code)
        }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw ServerError.listen(code)
        }

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    public func stop() {
        source?.cancel()
        source = nil
        listenFD = -1
        unlink(path)
    }

    private func acceptClient() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let line = Self.readLine(from: client)
        close(client)
        if let line, !line.isEmpty { onLine(line) }
    }

    static func readLine(from fd: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < maxLineBytes {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            if let newline = buffer[0..<count].firstIndex(of: UInt8(ascii: "\n")) {
                data.append(contentsOf: buffer[0..<newline])
                return data
            }
            data.append(contentsOf: buffer[0..<count])
        }
        return data.isEmpty ? nil : data.prefix(maxLineBytes)
    }
}
