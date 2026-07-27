import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Errors surfaced by the low-level socket layer.
public enum SocketError: Error, Sendable, Equatable {
    case connectFailed(path: String, errno: Int32)
    case writeFailed(errno: Int32)
    case timedOut
    case closed
    case pathTooLong(path: String)
}

/// A single blocking AF_UNIX stream connection with newline-delimited framing.
///
/// herdr closes the socket after one request/response, so most uses are
/// connect → write one line → read lines → close. The event subscription keeps
/// one connection open and reads pushed lines until the peer closes.
///
/// This wraps raw POSIX fds. Blocking calls (`connect`, `readLine`) must be run
/// off the main actor — `HerdrClient` does this on a background queue.
final class SocketConnection: @unchecked Sendable {
    private var fd: Int32 = -1
    private var readBuffer = Data()
    private let ioTimeout: TimeInterval?
    let path: String

    init(path: String, ioTimeout: TimeInterval? = nil) {
        self.path = path
        self.ioTimeout = ioTimeout
    }

    var isOpen: Bool { fd >= 0 }

    /// Establish the connection. Blocking.
    func connect() throws {
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { throw SocketError.connectFailed(path: path, errno: errno) }
        if let ioTimeout {
            var timeout = timeval(
                tv_sec: Int(ioTimeout),
                tv_usec: Int32((ioTimeout.truncatingRemainder(dividingBy: 1)) * 1_000_000))
            let size = socklen_t(MemoryLayout<timeval>.size)
            withUnsafePointer(to: &timeout) { pointer in
                _ = setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, pointer, size)
                _ = setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, pointer, size)
            }
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < maxLen else {
            Darwin.close(sock)
            throw SocketError.pathTooLong(path: path)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLen) { dst in
                for (i, byte) in pathBytes.enumerated() { dst[i] = CChar(bitPattern: byte) }
                dst[pathBytes.count] = 0
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { aptr in
            aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Foundation.connect(sock, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            let e = errno
            Darwin.close(sock)
            throw SocketError.connectFailed(path: path, errno: e)
        }
        fd = sock
    }

    /// Write bytes followed by a newline. Blocking; retries partial writes.
    func writeLine(_ data: Data) throws {
        guard fd >= 0 else { throw SocketError.closed }
        var payload = data
        payload.append(0x0A)  // '\n'
        try payload.withUnsafeBytes { raw in
            var total = 0
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while total < payload.count {
                let n = Foundation.write(fd, base + total, payload.count - total)
                if n > 0 {
                    total += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw SocketError.timedOut
                } else {
                    throw SocketError.writeFailed(errno: errno)
                }
            }
        }
    }

    /// Read one newline-delimited line (without the trailing newline).
    /// Returns nil at EOF (peer closed). Blocking.
    func readLine() throws -> Data? {
        while true {
            if let nl = readBuffer.firstIndex(of: 0x0A) {
                let line = readBuffer.subdata(in: readBuffer.startIndex..<nl)
                readBuffer.removeSubrange(readBuffer.startIndex...nl)
                return line
            }
            guard fd >= 0 else { throw SocketError.closed }
            var chunk = [UInt8](repeating: 0, count: 8192)
            let n = chunk.withUnsafeMutableBytes { Foundation.read(fd, $0.baseAddress, 8192) }
            if n > 0 {
                readBuffer.append(contentsOf: chunk[0..<n])
            } else if n == 0 {
                // EOF. Return any trailing partial line, then nil next call.
                if !readBuffer.isEmpty {
                    let line = readBuffer
                    readBuffer.removeAll()
                    return line
                }
                return nil
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                throw SocketError.timedOut
            } else {
                throw SocketError.closed
            }
        }
    }

    func close() {
        if fd >= 0 {
            Foundation.close(fd)
            fd = -1
        }
    }

    deinit { close() }
}
