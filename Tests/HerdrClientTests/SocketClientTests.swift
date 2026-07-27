import Foundation
import Testing
@testable import HerdrClient

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite("Socket path resolution")
struct SocketPathTests {
    @Test("explicit path wins and expands tilde")
    func explicitWins() {
        let p = SocketPath.resolve(
            explicit: "~/custom/herdr.sock",
            environment: ["HERDR_SOCKET_PATH": "/env/path.sock", "HERDR_SESSION": "w"])
        #expect(p == NSString(string: "~/custom/herdr.sock").expandingTildeInPath)
        #expect(!p.contains("~"))
    }

    @Test("HERDR_SOCKET_PATH beats HERDR_SESSION and default")
    func socketPathEnv() {
        let p = SocketPath.resolve(environment: ["HERDR_SOCKET_PATH": "/tmp/x.sock", "HERDR_SESSION": "w"])
        #expect(p == "/tmp/x.sock")
    }

    @Test("HERDR_SESSION maps to sessions/<name>/herdr.sock")
    func sessionEnv() {
        let p = SocketPath.resolve(environment: ["HERDR_SESSION": "work"])
        #expect(p == NSString(string: "~/.config/herdr/sessions/work/herdr.sock").expandingTildeInPath)
    }

    @Test("empty environment falls back to default")
    func defaultPath() {
        let p = SocketPath.resolve(environment: [:])
        #expect(p == SocketPath.defaultPath)
    }

    @Test("empty env values are ignored")
    func emptyValuesIgnored() {
        let p = SocketPath.resolve(environment: ["HERDR_SOCKET_PATH": "", "HERDR_SESSION": ""])
        #expect(p == SocketPath.defaultPath)
    }

    @Test("the default session is NOT under sessions/")
    func defaultSessionIsNotNested() {
        // herdr puts the default session's socket at ~/.config/herdr/herdr.sock.
        // Deriving it from the name was wrong for the most common session of all.
        #expect(SocketPath.forSession("default") == SocketPath.defaultPath)
        #expect(SocketPath.forSession("") == SocketPath.defaultPath)
        #expect(SocketPath.resolve(environment: ["HERDR_SESSION": "default"])
            == SocketPath.defaultPath)
    }
}

@Suite("Backoff policy")
struct BackoffTests {
    @Test("delay grows then caps")
    func growsAndCaps() {
        let b = BackoffPolicy(base: 0.25, max: 5.0, multiplier: 2.0)
        #expect(b.delay(forAttempt: 0) == 0)
        #expect(b.delay(forAttempt: 1) == 0.25)
        #expect(b.delay(forAttempt: 2) == 0.5)
        #expect(b.delay(forAttempt: 3) == 1.0)
        #expect(b.delay(forAttempt: 100) == 5.0) // capped
    }
}

/// A minimal in-process AF_UNIX server that speaks the herdr framing so we can
/// test request/response correlation and the event stream without a live herdr.
final class FakeHerdrServer: @unchecked Sendable {
    let path: String
    private var listenFd: Int32 = -1
    /// Called with the parsed request object; returns response line(s) to write.
    private let handler: @Sendable (JSONValue) -> [JSONValue]
    /// When true, the server closes the connection even after a subscription's
    /// responses — used to exercise the client's reconnect + re-subscribe.
    private let closeAfterEverything: Bool

    init(closeAfterEverything: Bool = false,
         handler: @escaping @Sendable (JSONValue) -> [JSONValue]) {
        self.path = NSTemporaryDirectory() + "fake-herdr-\(UInt64.random(in: 0...UInt64.max)).sock"
        self.handler = handler
        self.closeAfterEverything = closeAfterEverything
    }

    func start() throws {
        unlink(path)
        listenFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFd >= 0 else { throw SocketError.connectFailed(path: path, errno: errno) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[bytes.count] = 0
            }
        }
        let bindResult = withUnsafePointer(to: &addr) { addr in
            addr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(listenFd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else { throw SocketError.connectFailed(path: path, errno: errno) }
        // Some tests intentionally open 40 connections at once. A tiny backlog
        // makes connect() intermittently fail with ECONNREFUSED before the
        // detached accept loop gets scheduled, which tests scheduler timing
        // instead of request correlation.
        guard listen(listenFd, SOMAXCONN) == 0 else {
            throw SocketError.connectFailed(path: path, errno: errno)
        }
        let fd = listenFd
        let handler = self.handler
        let closeAfterEverything = self.closeAfterEverything
        Thread.detachNewThread {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { break }
                Thread.detachNewThread {
                    Self.serve(client: client, handler: handler,
                               closeAfterEverything: closeAfterEverything)
                }
            }
        }
    }

    private static func serve(client: Int32,
                              handler: @escaping @Sendable (JSONValue) -> [JSONValue],
                              closeAfterEverything: Bool = false) {
        var buffer = Data()
        func readLine() -> Data? {
            while true {
                if let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.subdata(in: buffer.startIndex..<nl)
                    buffer.removeSubrange(buffer.startIndex...nl)
                    return line
                }
                var chunk = [UInt8](repeating: 0, count: 4096)
                let n = chunk.withUnsafeMutableBytes { raw in
                    recv(client, raw.baseAddress, 4096, 0)
                }
                if n > 0 { buffer.append(contentsOf: chunk[0..<n]) } else { return nil }
            }
        }
        func writeLine(_ v: JSONValue) {
            guard var data = try? v.serialized() else { return }
            data.append(0x0A)
            _ = data.withUnsafeBytes { raw in
                send(client, raw.baseAddress, data.count, 0)
            }
        }
        while let line = readLine() {
            guard let req = try? JSONValue.parse(line) else { continue }
            for resp in handler(req) { writeLine(resp) }
            // herdr closes after a single request/response unless it's a subscription.
            if req["method"]?.stringValue != "events.subscribe" { break }
            // Optionally drop the subscription connection to force a reconnect.
            if closeAfterEverything { break }
        }
        Foundation.close(client)
    }

    func stop() {
        if listenFd >= 0 { Foundation.close(listenFd); listenFd = -1 }
        unlink(path)
    }

    deinit { stop() }
}

@Suite("HerdrClient request/response against a fake server")
struct HerdrClientRequestTests {
    @Test("ping returns result and correlates by echoing id")
    func pingRoundTrip() async throws {
        let server = FakeHerdrServer { req in
            let id = req["id"]?.stringValue ?? "?"
            return [.object(["id": .string(id), "result": .object(["pong": .bool(true)])])]
        }
        try server.start()
        defer { server.stop() }

        let client = HerdrClient(socketPath: server.path)
        let result = try await client.request("ping")
        #expect(result["pong"]?.boolValue == true)
    }

    @Test("error envelope throws HerdrError.api")
    func errorEnvelope() async throws {
        let server = FakeHerdrServer { req in
            let id = req["id"]?.stringValue ?? "?"
            return [.object(["id": .string(id),
                             "error": .object(["code": .string("bad_request"),
                                               "message": .string("nope")])])]
        }
        try server.start()
        defer { server.stop() }

        let client = HerdrClient(socketPath: server.path)
        await #expect(throws: HerdrError.self) {
            try await client.request("pane.focus", params: .object(["pane_id": .string("w.1:p1")]))
        }
    }

    @Test("a bounded request cannot hang forever after connecting")
    func requestTimeout() async throws {
        let server = FakeHerdrServer { _ in
            Thread.sleep(forTimeInterval: 0.5)
            return []
        }
        try server.start()
        defer { server.stop() }

        let client = HerdrClient(socketPath: server.path, requestTimeout: 0.1)
        await #expect(throws: SocketError.timedOut) {
            try await client.request("ping")
        }
    }

    @Test("concurrent requests each get their own connection + correct result")
    func concurrentCorrelation() async throws {
        // Each connect-per-call is independent; assert N concurrent calls all resolve
        // to the id they sent (proves no cross-talk).
        let server = FakeHerdrServer { req in
            let id = req["id"]?.stringValue ?? "?"
            return [.object(["id": .string(id), "result": .object(["echo": .string(id)])])]
        }
        try server.start()
        defer { server.stop() }

        let client = HerdrClient(socketPath: server.path)
        try await withThrowingTaskGroup(of: (String, String).self) { group in
            for i in 0..<40 {
                let id = "req_\(i)"
                group.addTask {
                    let r = try await client.request("ping", id: id)
                    return (id, r["echo"]?.stringValue ?? "")
                }
            }
            for try await (sent, got) in group {
                #expect(sent == got)
            }
        }
    }

    @Test("event stream yields pushed events after the ack")
    func eventStream() async throws {
        let server = FakeHerdrServer { req in
            // On subscribe: ack, then two pushed events.
            if req["method"]?.stringValue == "events.subscribe" {
                let id = req["id"]?.stringValue ?? "sub"
                return [
                    .object(["id": .string(id), "result": .object(["ok": .bool(true)])]),
                    .object(["event": .string("pane_agent_detected"),
                             "data": .object(["pane_id": .string("w.1:p1")])]),
                    .object(["event": .string("pane_created"),
                             "data": .object(["pane_id": .string("w.1:p2")])]),
                ]
            }
            return []
        }
        try server.start()
        defer { server.stop() }

        let client = HerdrClient(socketPath: server.path)
        let stream = client.events(subscriptions: { [Subscription(type: "pane.agent_detected")] })
        var received: [String] = []
        for await event in stream {
            if let name = event["event"]?.stringValue { received.append(name) }
            if received.count == 2 { break }
        }
        #expect(received == ["pane_agent_detected", "pane_created"])
    }

    @Test("event stream reconnects and re-subscribes after the connection drops")
    func eventStreamReconnects() async throws {
        // The server closes after emitting on each subscription; the client must
        // reconnect (fast backoff) and re-subscribe, so we keep receiving events
        // and the subscribe handler is invoked more than once.
        let subscribeCount = Counter()
        let server = FakeHerdrServer(closeAfterEverything: true) { req in
            if req["method"]?.stringValue == "events.subscribe" {
                subscribeCount.increment()
                let id = req["id"]?.stringValue ?? "sub"
                return [
                    .object(["id": .string(id), "result": .object(["ok": .bool(true)])]),
                    .object(["event": .string("pane_created"), "data": .object([:])]),
                ]
            }
            return []
        }
        try server.start()
        defer { server.stop() }

        let client = HerdrClient(socketPath: server.path)
        // Tiny backoff so the test is fast.
        let stream = client.events(subscriptions: { [Subscription(type: "pane.created")] },
                                   backoff: BackoffPolicy(base: 0.01, max: 0.05, multiplier: 1.5))
        var count = 0
        for await event in stream {
            if event["event"]?.stringValue == "pane_created" { count += 1 }
            if count == 3 { break } // three separate connections' worth of events
        }
        #expect(count == 3)
        #expect(subscribeCount.value >= 3) // re-subscribed on each reconnect
    }
}

/// Thread-safe counter for cross-thread assertions in the fake server.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    func increment() { lock.withLock { _value += 1 } }
    var value: Int { lock.withLock { _value } }
}
