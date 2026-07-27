import Foundation

/// Errors from the request/response layer.
public enum HerdrError: Error, Sendable {
    /// The server returned `{"id","error":{code,message}}`.
    case api(code: String, message: String)
    /// Connection closed before a response line arrived.
    case noResponse(method: String)
    /// Response was not a JSON object.
    case malformedResponse(method: String)
}

/// A subscription entry for `events.subscribe`.
///
/// Note (herdr 0.7.x): `pane.agent_status_changed` REQUIRES a `paneID`; the
/// global lifecycle events (`pane.agent_detected`, `pane.created`,
/// `pane.exited`) take only a `type`. There is no global status firehose.
public struct Subscription: Sendable, Hashable {
    public let type: String
    public let paneID: String?

    public init(type: String, paneID: String? = nil) {
        self.type = type
        self.paneID = paneID
    }

    var json: JSONValue {
        var obj: [String: JSONValue] = ["type": .string(type)]
        if let paneID { obj["pane_id"] = .string(paneID) }
        return .object(obj)
    }
}

/// Abstraction over the request/response layer so higher layers (the action
/// layer, spec 05) can be unit-tested against a recording mock without a socket.
public protocol RequestSending: Sendable {
    @discardableResult
    func request(_ method: String, params: JSONValue, id: String) async throws -> JSONValue
}

extension RequestSending {
    @discardableResult
    public func request(_ method: String, params: JSONValue = .object([:])) async throws -> JSONValue {
        try await request(method, params: params, id: "1")
    }
}

/// Async client for the herdr newline-delimited JSON socket API.
///
/// - `request(_:params:)` uses **connect-per-call** — herdr closes the socket
///   after a single request/response, so we never multiplex requests on one
///   connection.
/// - `events(_:)` opens a *separate* long-lived connection, sends
///   `events.subscribe`, and streams pushed lines, reconnecting with backoff.
public final class HerdrClient: RequestSending, Sendable {
    public let socketPath: String
    /// Optional bound for one-shot request reads/writes. Event subscriptions
    /// deliberately remain unbounded and are interrupted by cancellation.
    private let requestTimeout: TimeInterval?
    /// **Concurrent** queue: request/response calls use short-lived blocking work,
    /// and the event subscription runs a *long-lived* blocking read loop. A serial
    /// queue would let the events loop's infinite `readLine()` starve every
    /// `request()` (e.g. the resubscribe loop's `session.snapshot`) → deadlock. A
    /// concurrent queue lets each blocking socket call run on its own thread.
    private let queue = DispatchQueue(label: "dev.notchagent.herdr.socket",
                                      qos: .userInitiated, attributes: .concurrent)

    public init(socketPath: String? = nil, requestTimeout: TimeInterval? = nil) {
        self.socketPath = SocketPath.resolve(explicit: socketPath)
        self.requestTimeout = requestTimeout
    }

    /// Set `HERDR_DEBUG_EVENTS=1` to trace the event loop to stderr.
    private var debugEvents: Bool { ProcessInfo.processInfo.environment["HERDR_DEBUG_EVENTS"] == "1" }

    // MARK: Request / response (connect-per-call)

    /// Send one request and return its `result` value (throws on `error`).
    @discardableResult
    public func request(_ method: String, params: JSONValue = .object([:]),
                        id: String = "1") async throws -> JSONValue {
        let requestObj: JSONValue = .object([
            "id": .string(id),
            "method": .string(method),
            "params": params,
        ])
        let payload = try requestObj.serialized()
        let path = socketPath
        let requestTimeout = requestTimeout

        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                let conn = SocketConnection(path: path, ioTimeout: requestTimeout)
                defer { conn.close() }
                do {
                    try conn.connect()
                    try conn.writeLine(payload)
                    guard let line = try conn.readLine() else {
                        cont.resume(throwing: HerdrError.noResponse(method: method))
                        return
                    }
                    let msg = try JSONValue.parse(line)
                    if let err = msg["error"], !err.isNull {
                        cont.resume(throwing: HerdrError.api(
                            code: err["code"]?.stringValue ?? "unknown",
                            message: err["message"]?.stringValue ?? String(describing: err)))
                        return
                    }
                    cont.resume(returning: msg["result"] ?? .null)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Protocol probe. Returns true if `ping` succeeds.
    public func ping() async -> Bool {
        (try? await request("ping")) != nil
    }

    // MARK: Event subscription (long-lived, reconnecting)

    /// A stream of pushed event envelopes. Reconnects with capped exponential
    /// backoff and re-subscribes on each (re)connect. The subscription list can
    /// be provided by a closure so callers (the state store) can re-derive it —
    /// e.g. after new panes appear — on every reconnect.
    public func events(
        subscriptions: @escaping @Sendable () -> [Subscription],
        backoff: BackoffPolicy = .default
    ) -> AsyncStream<JSONValue> {
        let path = socketPath
        let queue = self.queue
        let debugEvents = self.debugEvents
        return AsyncStream { continuation in
            let state = EventLoopState()
            continuation.onTermination = { _ in state.stop() }
            queue.async {
                var attempt = 0
                while !state.isStopped {
                    let conn = SocketConnection(path: path)
                    do {
                        try conn.connect()
                        state.setConnection(conn)
                        attempt = 0
                        let subs = subscriptions().map(\.json)
                        let sub: JSONValue = .object([
                            "id": .string("sub"),
                            "method": .string("events.subscribe"),
                            "params": .object(["subscriptions": .array(subs)]),
                        ])
                        try conn.writeLine(sub.serialized())
                        if debugEvents { FileHandle.standardError.write(Data("[events] subscribed with \(subs.count) subs\n".utf8)) }
                        while !state.isStopped {
                            guard let line = try conn.readLine() else { break }  // EOF → reconnect
                            if debugEvents { FileHandle.standardError.write(Data("[events] line: \(String(data: line, encoding: .utf8)?.prefix(80) ?? "")\n".utf8)) }
                            if let msg = try? JSONValue.parse(line) {
                                // A subscribe error means the batch was malformed —
                                // retrying identically just tight-loops. Surface it
                                // and stop rather than hammering herdr forever.
                                if let err = msg["error"], !err.isNull {
                                    if debugEvents { FileHandle.standardError.write(Data("[events] subscribe rejected: \(err["message"]?.stringValue ?? "")\n".utf8)) }
                                    continuation.yield(.object([
                                        "event": .string("__subscribe_error"),
                                        "data": err,
                                    ]))
                                    state.stop()
                                    break
                                }
                                // Skip the subscribe ack (id == "sub"); forward events.
                                if msg["id"]?.stringValue == "sub" { continue }
                                continuation.yield(msg)
                            }
                        }
                    } catch {
                        if debugEvents { FileHandle.standardError.write(Data("[events] error: \(error)\n".utf8)) }
                        // fall through to backoff + reconnect
                    }
                    conn.close()
                    if state.isStopped { break }
                    attempt += 1
                    let delay = backoff.delay(forAttempt: attempt)
                    Thread.sleep(forTimeInterval: delay)
                }
                continuation.finish()
            }
        }
    }
}

/// Capped exponential backoff.
public struct BackoffPolicy: Sendable {
    public let base: TimeInterval
    public let max: TimeInterval
    public let multiplier: Double

    public init(base: TimeInterval = 0.25, max: TimeInterval = 5.0, multiplier: Double = 2.0) {
        self.base = base
        self.max = max
        self.multiplier = multiplier
    }

    public static let `default` = BackoffPolicy()

    public func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        let raw = base * pow(multiplier, Double(attempt - 1))
        return Swift.min(raw, max)
    }
}

/// Thread-safe flag + connection holder so `onTermination` can interrupt the
/// blocking read loop by closing the fd.
private final class EventLoopState: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var connection: SocketConnection?

    var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    func setConnection(_ conn: SocketConnection) {
        lock.lock(); defer { lock.unlock() }
        connection = conn
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        connection?.close()
    }
}
