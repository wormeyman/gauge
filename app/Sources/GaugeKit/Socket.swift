import Foundation

/// Serves newline-delimited requests on a Unix domain socket. The socket file is created with mode 0600
/// before it accepts anything, and connections from other user accounts are closed unanswered.
/// There's no TCP listener and nothing leaves the Mac.
public final class UnixSocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (Data) async -> Data

    public enum Failure: Error, CustomStringConvertible {
        case pathTooLong, notASocket(String), alreadyServing, system(String, Int32)
        public var description: String {
            switch self {
            case .pathTooLong: "The socket path is too long."
            case .notASocket(let path): "\(path) exists and isn't a socket, so Gauge left it alone."
            case .alreadyServing: "Another copy of Gauge is already answering on this socket."
            case .system(let call, let code): "\(call) failed: \(String(cString: strerror(code)))"
            }
        }
    }

    /// Longest request line accepted.
    static let maxLine = 64 * 1024

    public let path: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "gauge.localapi.accept")
    private var source: DispatchSourceRead?
    private var inode: ino_t = 0

    public init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public func start() throws(Failure) {
        try removeStaleSocket()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .system("socket", errno) }
        var ok = false
        defer { if !ok { close(fd) } }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        guard var address = Self.address(path) else { throw .pathTooLong }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { throw .system("bind", errno) }
        // Owner-only before listen(), so there's no moment when another account could connect.
        guard chmod(path, 0o600) == 0 else { throw .system("chmod", errno) }
        guard listen(fd, 16) == 0 else { throw .system("listen", errno) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var info = stat()
        if lstat(path, &info) == 0 { inode = info.st_ino }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAll(fd) }
        source.setCancelHandler { close(fd) }
        self.source = source
        ok = true
        source.resume()
    }

    /// Stops listening and removes the socket file, if it's still the one this server made.
    public func stop() {
        source?.cancel()
        source = nil
        var info = stat()
        if inode != 0, lstat(path, &info) == 0, info.st_ino == inode, (info.st_mode & S_IFMT) == S_IFSOCK {
            unlink(path)
        }
        inode = 0
    }

    deinit { stop() }

    /// A socket file left by a Gauge that didn't quit cleanly blocks bind(). It's removed only when
    /// it's a socket and nothing answers on it.
    private func removeStaleSocket() throws(Failure) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        guard (info.st_mode & S_IFMT) == S_IFSOCK else { throw .notASocket(path) }
        if let fd = try? UnixSocketClient.connect(path) {
            close(fd)
            throw .alreadyServing
        }
        unlink(path)
    }

    private func acceptAll(_ listener: Int32) {
        while true {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { close(fd); continue }
            // Accepted sockets inherit the listener's non-blocking flag; each connection reads blocking on its own thread.
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            Self.configure(fd, timeout: 30)
            let handler = handler
            DispatchQueue.global(qos: .utility).async { Self.serve(fd, handler: handler) }
        }
    }

    /// Answers each request line on a connection until the client closes it or goes quiet.
    private static func serve(_ fd: Int32, handler: @escaping Handler) {
        defer { close(fd) }
        var reader = LineReader(fd: fd)
        while let line = reader.next() {
            if line.isEmpty { continue }
            let response = line.count > maxLine ? API.failure("Request too long.") : wait { await handler(line) }
            guard writeAll(fd, response + Data("\n".utf8)) else { return }
        }
    }

    /// Runs async work from a plain thread. The connection's thread is a GCD worker, not the main thread,
    /// so blocking it while the handler hops to the main actor can't deadlock.
    private static func wait(_ work: @escaping @Sendable () async -> Data) -> Data {
        final class Box: @unchecked Sendable { var data = Data() }
        let box = Box(), done = DispatchSemaphore(value: 0)
        Task.detached { box.data = await work(); done.signal() }
        done.wait()
        return box.data
    }

    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }

    static func configure(_ fd: Int32, timeout seconds: Int) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var time = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { return false }
                offset += n
            }
            return true
        }
    }
}

/// Splits what arrives on a socket into lines.
struct LineReader {
    let fd: Int32
    private var buffer = Data()
    private var finished = false

    init(fd: Int32) { self.fd = fd }

    /// The next line without its newline, or nil once the peer closes, times out or sends too much.
    mutating func next() -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return Data(line)
            }
            if finished || buffer.count > UnixSocketServer.maxLine * 2 {
                defer { buffer.removeAll() }
                return finished && !buffer.isEmpty ? buffer : nil
            }
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            let n = read(fd, &chunk, chunk.count)
            if n < 0, errno == EINTR { continue }
            if n <= 0 { finished = true; continue }
            buffer.append(contentsOf: chunk.prefix(n))
        }
    }
}

/// Talks to Gauge's local API.
public enum UnixSocketClient {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// No socket, or nothing listening on it.
        case notRunning
        /// Gauge answered with an error.
        case refused(String)
        case broken(String)

        public var description: String {
            switch self {
            case .notRunning: "Gauge isn't running, or 'Let local tools read Gauge' is off in Settings."
            case .refused(let message): message
            case .broken(let message): "Couldn't read Gauge's answer: \(message)"
            }
        }
    }

    static func connect(_ path: String) throws(Failure) -> Int32 {
        guard var address = UnixSocketServer.address(path) else { throw .broken("The socket path is too long.") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .broken(String(cString: strerror(errno))) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            if [ENOENT, ECONNREFUSED, ENOTSOCK, EACCES].contains(code) { throw .notRunning }
            throw .broken(String(cString: strerror(code)))
        }
        return fd
    }

    /// Sends one request and returns its result.
    public static func send(_ request: JSON, path: String = API.socketPath, timeout: Int = 15) throws(Failure) -> JSON {
        let fd = try connect(path)
        defer { close(fd) }
        UnixSocketServer.configure(fd, timeout: timeout)
        guard UnixSocketServer.writeAll(fd, request.data() + Data("\n".utf8)) else { throw .broken("the connection closed") }
        var reader = LineReader(fd: fd)
        guard let line = reader.next() else { throw .broken("no answer within \(timeout) seconds") }
        guard let response = try? JSON.parse(line) else { throw .broken("it wasn't JSON") }
        if response["ok"] == .bool(true), let result = response["result"] { return result }
        throw .refused(response["error"]?.string ?? "Gauge couldn't answer that.")
    }

    public static func send(_ request: Request, path: String = API.socketPath) throws(Failure) -> JSON {
        try send(request.json, path: path)
    }
}
