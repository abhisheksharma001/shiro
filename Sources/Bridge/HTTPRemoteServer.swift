import Foundation
import Network

// MARK: - HTTPRemoteServer
//
// Embedded HTTP server using Network.framework NWListener.
// Binds to 127.0.0.1:<port> (loopback + Tailscale-routable).
//
// Endpoints:
//   POST /v1/prompt   body: {"text":"...","sync":true|false}
//                     auth: Authorization: Bearer <token>
//                     sync=true  → hold connection until response ready (≤ 30s)
//                     sync=false → return {"id":"<uuid>","status":"queued"} immediately
//   GET  /v1/status   → {"running":<bool>,"model":"<name>","queue":<n>}
//   POST /v1/cancel   body: {"id":"<uuid>"}
//
// Auth: Bearer token stored in Keychain under "shiro_remote_token".
// If no token is stored, one is auto-generated on first start and saved.

@MainActor
final class HTTPRemoteServer: ObservableObject, RemoteReplySink {

    // MARK: - State

    @Published var isRunning = false
    @Published var port: UInt16 = 7421
    @Published var lastRequestAt: Date?
    @Published var queueDepth: Int = 0

    weak var appState: AppState?
    private var listener: NWListener?
    /// requestId → AsyncStream continuation (for sync mode)
    private var syncWaiters: [String: AsyncStream<String>.Continuation] = [:]
    /// requestId → accumulated response text (for async poll)
    private var asyncResults: [String: String] = [:]
    /// requestId → "pending"|"running"|"done"|"error"
    private var asyncStatus: [String: String] = [:]

    // MARK: - Token management

    static func ensureToken() -> String {
        if let existing = KeychainHelper.get(.shiroRemoteToken), !existing.isEmpty {
            return existing
        }
        let new = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        KeychainHelper.set(new, for: .shiroRemoteToken)
        return new
    }

    static func rotateToken() -> String {
        let new = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        KeychainHelper.set(new, for: .shiroRemoteToken)
        return new
    }

    // MARK: - Start / Stop

    func start() throws {
        guard !isRunning else { return }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        let p = NWEndpoint.Port(rawValue: port)!
        let l = try NWListener(using: params, on: p)

        l.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                switch state {
                case .ready:
                    self?.isRunning = true
                    print("[HTTPRemoteServer] listening on port \(self?.port ?? 0)")
                case .failed(let e):
                    self?.isRunning = false
                    self?.appState?.logError(source: "HTTPRemoteServer", message: "Listener failed: \(e)")
                default: break
                }
            }
        }

        l.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .global(qos: .userInitiated))
            Task { @MainActor [weak self] in
                await self?.handleConnection(conn)
            }
        }

        l.start(queue: .global(qos: .userInitiated))
        self.listener = l
        _ = HTTPRemoteServer.ensureToken()  // ensure token exists
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - Connection handler

    // [A7-fix] Read the complete HTTP request by looping until we have headers + full body.
    private func readFullRequest(_ conn: NWConnection) async -> Data {
        return await withCheckedContinuation { (cont: CheckedContinuation<Data, Never>) in
            var received = Data()

            func readMore() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { chunk, _, isComplete, error in
                    if let chunk, !chunk.isEmpty { received.append(chunk) }

                    // Check if we have a complete HTTP request (headers + body).
                    if let headerEnd = received.range(of: Data("\r\n\r\n".utf8)) {
                        // Parse Content-Length to decide if body is complete.
                        let headersData = received[..<headerEnd.lowerBound]
                        let headers = String(data: headersData, encoding: .utf8) ?? ""
                        var contentLength = 0
                        for line in headers.components(separatedBy: "\r\n") {
                            let lower = line.lowercased()
                            if lower.hasPrefix("content-length:"),
                               let val = Int(lower.dropFirst("content-length:".count)
                                .trimmingCharacters(in: .whitespaces)) {
                                contentLength = val
                            }
                        }
                        let bodyStart  = headerEnd.upperBound
                        let bodyReceived = received.count - bodyStart
                        if bodyReceived >= contentLength {
                            cont.resume(returning: received)
                            return
                        }
                    }

                    if isComplete || error != nil {
                        cont.resume(returning: received)
                        return
                    }
                    readMore()
                }
            }
            readMore()
        }
    }

    private func handleConnection(_ conn: NWConnection) async {
        let data = await readFullRequest(conn)

        guard let raw = String(data: data, encoding: .utf8) else {
            sendResponse(conn, status: 400, body: #"{"error":"Invalid UTF-8"}"#)
            return
        }

        // Parse HTTP request line + headers + body
        let parts = raw.components(separatedBy: "\r\n\r\n")
        let head  = parts[0]
        let body  = parts.count > 1 ? parts[1...].joined(separator: "\r\n\r\n") : ""
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendResponse(conn, status: 400, body: #"{"error":"Bad request"}"#)
            return
        }

        let reqParts = requestLine.components(separatedBy: " ")
        guard reqParts.count >= 2 else {
            sendResponse(conn, status: 400, body: #"{"error":"Bad request line"}"#)
            return
        }
        let method = reqParts[0]
        let path   = reqParts[1].components(separatedBy: "?")[0]

        // Auth check
        let authHeader = lines.first(where: { $0.lowercased().hasPrefix("authorization:") })
        let providedToken = authHeader?
            .components(separatedBy: ":")
            .dropFirst().joined(separator: ":")
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "Bearer ", with: "")
        let expectedToken = HTTPRemoteServer.ensureToken()
        guard providedToken == expectedToken else {
            sendResponse(conn, status: 401, body: #"{"error":"Unauthorized"}"#)
            return
        }

        lastRequestAt = Date()

        switch (method, path) {
        case ("POST", "/v1/prompt"):
            await handlePrompt(conn: conn, body: body)
        case ("GET", "/v1/status"):
            handleStatus(conn: conn)
        case ("POST", "/v1/cancel"):
            handleCancel(conn: conn, body: body)
        default:
            sendResponse(conn, status: 404, body: #"{"error":"Not found"}"#)
        }
    }

    // MARK: - /v1/prompt

    private func handlePrompt(conn: NWConnection, body: String) async {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            sendResponse(conn, status: 400, body: #"{"error":"Missing 'text' field"}"#)
            return
        }
        let sync = json["sync"] as? Bool ?? true
        let requestId = UUID().uuidString

        queueDepth += 1
        asyncStatus[requestId] = "running"

        if sync {
            // Hold connection — stream to accumulated string, reply when done
            var accumulated = ""
            let stream = await appState?.runRemotePrompt(text, source: "http") ?? AsyncStream { $0.finish() }
            for await chunk in stream { accumulated += chunk }
            queueDepth -= 1
            asyncStatus[requestId] = "done"
            asyncResults[requestId] = accumulated
            // [C4-fix] Use JSONSerialization — manual escaping misses \r, \t, control chars.
            let responseObj: [String: Any] = ["id": requestId, "status": "done", "text": accumulated]
            let responseBody = (try? JSONSerialization.data(withJSONObject: responseObj))
                .flatMap { String(data: $0, encoding: .utf8) }
                ?? #"{"id":"\#(requestId)","status":"done","text":"(encoding error)"}"#
            sendResponse(conn, status: 200, body: responseBody)
        } else {
            // Return immediately; result polled via /v1/status?id=<id>
            sendResponse(conn, status: 202,
                         body: #"{"id":"\#(requestId)","status":"queued"}"#)
            Task { [weak self] in
                guard let self else { return }
                var accumulated = ""
                let stream = await self.appState?.runRemotePrompt(text, source: "http")
                    ?? AsyncStream { $0.finish() }
                for await chunk in stream { accumulated += chunk }
                self.queueDepth -= 1
                self.asyncStatus[requestId]  = "done"
                self.asyncResults[requestId] = accumulated
            }
        }
    }

    // MARK: - /v1/status

    private func handleStatus(conn: NWConnection) {
        let model   = Config.activeModel ?? "default"
        let running = appState?.isRemoteProcessing ?? false
        let body    = #"{"running":\#(running),"model":"\#(model)","queue":\#(queueDepth)}"#
        sendResponse(conn, status: 200, body: body)
    }

    // MARK: - /v1/cancel

    private func handleCancel(conn: NWConnection, body: String) {
        appState?.agentCoordinator?.bridge?.interrupt(sessionKey: "main")
        appState?.isRemoteProcessing = false
        sendResponse(conn, status: 200, body: #"{"status":"cancelled"}"#)
    }

    // MARK: - HTTP response writer

    private func sendResponse(_ conn: NWConnection, status: Int, body: String) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 202: statusText = "Accepted"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 404: statusText = "Not Found"
        default:  statusText = "Error"
        }
        let bodyData = body.data(using: .utf8) ?? Data()
        let response = """
HTTP/1.1 \(status) \(statusText)\r\n\
Content-Type: application/json\r\n\
Content-Length: \(bodyData.count)\r\n\
Connection: close\r\n\
\r\n
"""
        var responseData = response.data(using: .utf8)!
        responseData.append(bodyData)
        conn.send(content: responseData, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - RemoteReplySink (for RemoteInbox integration)

    func streamChunk(_ text: String, replyToken: String?) async { /* no-op for HTTP */ }

    func streamFinished(replyToken: String?, finalText: String) async {
        guard let rid = replyToken else { return }
        asyncStatus[rid]  = "done"
        asyncResults[rid] = finalText
        syncWaiters[rid]?.yield(finalText)
        syncWaiters[rid]?.finish()
        syncWaiters.removeValue(forKey: rid)
    }

    func streamError(_ message: String, replyToken: String?) async {
        guard let rid = replyToken else { return }
        asyncStatus[rid] = "error"
        syncWaiters[rid]?.yield(message)
        syncWaiters[rid]?.finish()
        syncWaiters.removeValue(forKey: rid)
    }
}
