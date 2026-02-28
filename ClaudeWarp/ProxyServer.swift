import Foundation
import Network

/// HTTP server basato su NWListener (Network.framework), zero dipendenze esterne.
final class ProxyServer: @unchecked Sendable {
    private var listener: NWListener?
    private let state: AppState
    private let queue = DispatchQueue(label: "com.claudewarp.server", qos: .userInitiated)

    init(state: AppState) {
        self.state = state
    }

    // MARK: - Lifecycle

    func start() {
        stop()

        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: UInt16(state.port))!)
        } catch {
            state.lastError = "Impossibile creare listener: \(error.localizedDescription)"
            return
        }

        listener?.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            DispatchQueue.main.async {
                switch newState {
                case .ready:
                    self.state.isRunning = true
                    self.state.lastError = nil
                    print("[ClaudeWarp] Server avviato su \(self.state.endpointURL)")
                case .failed(let error):
                    self.state.isRunning = false
                    self.state.lastError = "Server error: \(error.localizedDescription)"
                    print("[ClaudeWarp] Server failed: \(error)")
                case .cancelled:
                    self.state.isRunning = false
                    print("[ClaudeWarp] Server fermato")
                default:
                    break
                }
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        DispatchQueue.main.async {
            self.state.isRunning = false
        }
    }

    // MARK: - Connection handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHTTPRequest(on: connection, accumulated: Data())
    }

    private func receiveHTTPRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error = error {
                print("[ClaudeWarp] Receive error: \(error)")
                connection.cancel()
                return
            }

            var buffer = accumulated
            if let data = data {
                buffer.append(data)
            }

            // Check if we have a complete HTTP request
            if let request = self.parseHTTPRequest(from: buffer) {
                self.routeRequest(request, on: connection)
            } else if isComplete {
                // Connection closed before complete request
                connection.cancel()
            } else {
                // Need more data
                self.receiveHTTPRequest(on: connection, accumulated: buffer)
            }
        }
    }

    // MARK: - HTTP parsing

    private struct HTTPRequest {
        let method: String
        let path: String
        let headers: [(String, String)]
        let body: Data
    }

    private func parseHTTPRequest(from data: Data) -> HTTPRequest? {
        // Find \r\n\r\n separator in raw bytes
        let separator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A] // \r\n\r\n
        let bytes = Array(data)
        var separatorIndex: Int?
        for i in 0...(bytes.count - separator.count) {
            if bytes[i] == separator[0] && bytes[i+1] == separator[1]
                && bytes[i+2] == separator[2] && bytes[i+3] == separator[3] {
                separatorIndex = i
                break
            }
        }
        guard let sepIdx = separatorIndex else { return nil }

        let headerData = Data(bytes[0..<sepIdx])
        guard let headerSection = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerSection.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }

        // Parse request line
        let requestLine = lines[0].components(separatedBy: " ")
        guard requestLine.count >= 2 else { return nil }
        let method = requestLine[0]
        let path = requestLine[1]

        // Parse headers
        var headers: [(String, String)] = []
        var contentLength = 0
        for i in 1..<lines.count {
            let parts = lines[i].split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
                let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                headers.append((key, value))
                if key.lowercased() == "content-length", let len = Int(value) {
                    contentLength = len
                }
            }
        }

        // Body starts after \r\n\r\n
        let bodyStart = sepIdx + 4
        let availableBody = bytes.count - bodyStart

        // Check if we have the full body
        if availableBody < contentLength {
            return nil // Need more data
        }

        let body = Data(bytes[bodyStart..<(bodyStart + contentLength)])
        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    // MARK: - Routing

    private func routeRequest(_ request: HTTPRequest, on connection: NWConnection) {
        let hdrs = request.headers.map { "\($0.0): \($0.1)" }.joined(separator: ", ")
        print("[ClaudeWarp] \(request.method) \(request.path) | headers=[\(hdrs)]")

        // Handle CORS preflight
        if request.method == "OPTIONS" {
            sendResponse(on: connection, status: 204, statusText: "No Content", headers: corsHeaders(), body: Data())
            return
        }

        switch (request.method, request.path) {
        case ("GET", "/health"):
            handleHealth(on: connection)

        case ("GET", "/v1/models"):
            handleModels(on: connection)

        case ("POST", "/v1/messages"):
            DispatchQueue.main.async { self.state.incrementRequestCount() }
            handleMessages(request, on: connection)

        default:
            print("[ClaudeWarp] 404 Not Found: \(request.method) \(request.path)")
            let body = #"{"type":"error","error":{"type":"not_found_error","message":"Not Found"}}"#.data(using: .utf8)!
            sendResponse(on: connection, status: 404, statusText: "Not Found",
                        headers: corsHeaders(contentType: "application/json"), body: body)
        }
    }

    // MARK: - Health endpoint

    private func handleHealth(on connection: NWConnection) {
        let body = #"{"status":"ok","backend":"claude-cli"}"#.data(using: .utf8)!
        sendResponse(on: connection, status: 200, statusText: "OK",
                    headers: corsHeaders(contentType: "application/json"), body: body)
    }

    // MARK: - Models endpoint

    private func handleModels(on connection: NWConnection) {
        let models = state.availableModels.isEmpty
            ? ["claude-opus-4-6", "claude-sonnet-4-6", "claude-haiku-4-5-20251001"]
            : state.availableModels

        let modelObjects = models.map { id -> [String: Any] in
            [
                "id": id,
                "type": "model",
                "display_name": id,
                "created_at": "2025-01-01T00:00:00Z",
            ]
        }
        let response: [String: Any] = [
            "data": modelObjects,
            "has_more": false,
            "first_id": models.first ?? "",
            "last_id": models.last ?? "",
        ]
        let body = try! JSONSerialization.data(withJSONObject: response)
        sendResponse(on: connection, status: 200, statusText: "OK",
                    headers: corsHeaders(contentType: "application/json"), body: body)
    }

    // MARK: - Messages endpoint

    private func handleMessages(_ request: HTTPRequest, on connection: NWConnection) {
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            let body = #"{"type":"error","error":{"type":"invalid_request_error","message":"Invalid JSON body"}}"#.data(using: .utf8)!
            sendResponse(on: connection, status: 400, statusText: "Bad Request",
                        headers: corsHeaders(contentType: "application/json"), body: body)
            return
        }

        let modelName = json["model"] as? String ?? "claude-sonnet-4-20250514"
        let system = json["system"]
        let messages = json["messages"] as? [[String: Any]] ?? []
        let tools = json["tools"] as? [[String: Any]]
        let stream = json["stream"] as? Bool ?? false

        let prompt = ClaudeBridge.formatMessages(messages)
        let systemPrompt = ClaudeBridge.buildSystemPrompt(system: system)
        let effectiveModel = state.selectedModel.isEmpty ? modelName : state.selectedModel
        let modelFlag = ClaudeBridge.resolveModelFlag(effectiveModel)
        let claudePath = state.claudePath
        let configDir = state.activeEnvironment?.configDir

        let hasTools = tools != nil && !(tools!.isEmpty)

        let envName = state.activeEnvironment?.name ?? "default"
        print("[ClaudeWarp] env=\(envName) | model=\(modelName) -> --model \(modelFlag) | messages=\(messages.count) | tools=\(tools?.count ?? 0) | stream=\(stream) | enableTools=\(hasTools)")

        if stream {
            sendRealStreamingResponse(
                on: connection, prompt: prompt, systemPrompt: systemPrompt,
                modelFlag: modelFlag, modelName: modelName,
                claudePath: claudePath, configDir: configDir, enableTools: hasTools
            )
        } else {
            Task {
                let startTime = Date()
                let result: CLIResult
                do {
                    result = try await ClaudeBridge.call(
                        prompt: prompt, systemPrompt: systemPrompt,
                        modelFlag: modelFlag, claudePath: claudePath,
                        configDir: configDir, enableTools: hasTools
                    )
                } catch {
                    let errResult = CLIResult(text: "Bridge error: \(error.localizedDescription)",
                                              inputTokens: 0, outputTokens: 0, isError: true)
                    self.sendErrorResponse(on: connection, result: errResult, stream: false)
                    return
                }

                let elapsed = Date().timeIntervalSince(startTime)
                print("[ClaudeWarp] claude responded in \(String(format: "%.1f", elapsed))s | error=\(result.isError)")

                if result.isError {
                    DispatchQueue.main.async { self.state.lastError = result.text }
                    self.sendErrorResponse(on: connection, result: result, stream: false)
                    return
                }

                let msgId = "msg_proxy_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))"
                let response: [String: Any] = [
                    "id": msgId,
                    "type": "message",
                    "role": "assistant",
                    "content": [["type": "text", "text": result.text]],
                    "model": modelName,
                    "stop_reason": "end_turn",
                    "stop_sequence": NSNull(),
                    "usage": [
                        "input_tokens": result.inputTokens,
                        "output_tokens": result.outputTokens,
                        "cache_creation_input_tokens": 0,
                        "cache_read_input_tokens": 0,
                    ],
                ]
                let body = try! JSONSerialization.data(withJSONObject: response)
                self.sendResponse(on: connection, status: 200, statusText: "OK",
                                headers: self.corsHeaders(contentType: "application/json"), body: body)
            }
        }
    }

    // MARK: - Real streaming response (NDJSON → SSE relay)

    private func sendRealStreamingResponse(
        on connection: NWConnection,
        prompt: String,
        systemPrompt: String?,
        modelFlag: String,
        modelName: String,
        claudePath: String,
        configDir: String?,
        enableTools: Bool
    ) {
        Task {
            let startTime = Date()
            let msgId = "msg_proxy_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))"

            // Mutable state per il relay multi-turn
            var headersSent = false
            var messageStartSent = false
            var virtualIndex = 0        // indice ricalcolato (solo text blocks)
            var activeTextBlock = false  // dentro un text block?
            var pingSent = false
            var lastMessageDelta: [String: Any]? = nil

            // --- Helper per inviare dati sulla connessione ---

            func sendHeaders() {
                guard !headersSent else { return }
                headersSent = true
                let h = "HTTP/1.1 200 OK\r\n"
                    + self.corsHeaders(contentType: "text/event-stream")
                    + "Cache-Control: no-cache\r\n"
                    + "\r\n"
                if let data = h.data(using: .utf8) {
                    connection.send(content: data, completion: .contentProcessed { _ in })
                }
            }

            func sendSSEEvent(_ event: String, _ data: [String: Any]) {
                guard let jsonData = try? JSONSerialization.data(withJSONObject: data),
                      let jsonStr = String(data: jsonData, encoding: .utf8) else { return }
                let sse = "event: \(event)\ndata: \(jsonStr)\n\n"
                if let sseData = sse.data(using: .utf8) {
                    connection.send(content: sseData, completion: .contentProcessed { _ in })
                }
            }

            func finishConnection(_ event: String, _ data: [String: Any]) {
                guard let jsonData = try? JSONSerialization.data(withJSONObject: data),
                      let jsonStr = String(data: jsonData, encoding: .utf8) else {
                    connection.cancel()
                    return
                }
                let sse = "event: \(event)\ndata: \(jsonStr)\n\n"
                if let sseData = sse.data(using: .utf8) {
                    connection.send(content: sseData, contentContext: .finalMessage, isComplete: true,
                                   completion: .contentProcessed { _ in connection.cancel() })
                }
            }

            // --- Streaming call ---

            let result: CLIResult
            do {
                result = try await ClaudeBridge.callStreaming(
                    prompt: prompt,
                    systemPrompt: systemPrompt,
                    modelFlag: modelFlag,
                    claudePath: claudePath,
                    configDir: configDir,
                    enableTools: enableTools
                ) { event in
                    switch event {

                    // --- message_start: relay solo il primo ---
                    case .messageStart(let data):
                        guard !messageStartSent else { return }
                        messageStartSent = true
                        sendHeaders()

                        var modified = data
                        if var message = modified["message"] as? [String: Any] {
                            message["id"] = msgId
                            message["content"] = [] as [Any]
                            message["stop_reason"] = NSNull()
                            message["stop_sequence"] = NSNull()
                            modified["message"] = message
                        }
                        sendSSEEvent("message_start", modified)

                    // --- content_block_start: relay solo text, skip thinking/tool_use ---
                    case .contentBlockStart(_, let data):
                        let contentBlock = (data["content_block"] as? [String: Any]) ?? [:]
                        let blockType = contentBlock["type"] as? String ?? ""

                        if blockType == "text" {
                            activeTextBlock = true
                            sendSSEEvent("content_block_start", [
                                "type": "content_block_start",
                                "index": virtualIndex,
                                "content_block": ["type": "text", "text": ""],
                            ] as [String: Any])

                            if !pingSent {
                                pingSent = true
                                sendSSEEvent("ping", ["type": "ping"])
                            }
                        } else {
                            activeTextBlock = false
                        }

                    // --- content_block_delta: relay solo text_delta ---
                    case .contentBlockDelta(_, let data):
                        guard activeTextBlock else { return }
                        let delta = (data["delta"] as? [String: Any]) ?? [:]
                        let deltaType = delta["type"] as? String ?? ""

                        if deltaType == "text_delta" {
                            sendSSEEvent("content_block_delta", [
                                "type": "content_block_delta",
                                "index": virtualIndex,
                                "delta": delta,
                            ] as [String: Any])
                        }

                    // --- content_block_stop: relay solo se era text block ---
                    case .contentBlockStop(_):
                        guard activeTextBlock else { return }
                        sendSSEEvent("content_block_stop", [
                            "type": "content_block_stop",
                            "index": virtualIndex,
                        ] as [String: Any])
                        virtualIndex += 1
                        activeTextBlock = false

                    // --- message_delta: salva (inviamo l'ultimo alla fine) ---
                    case .messageDelta(let data):
                        lastMessageDelta = data

                    // --- message_stop: skip (inviamo alla fine) ---
                    case .messageStop:
                        break
                    }
                }
            } catch {
                result = CLIResult(text: "Bridge error: \(error.localizedDescription)",
                                   inputTokens: 0, outputTokens: 0, isError: true)
            }

            let elapsed = Date().timeIntervalSince(startTime)
            print("[ClaudeWarp] streaming response in \(String(format: "%.1f", elapsed))s | error=\(result.isError) | textBlocks=\(virtualIndex)")

            if result.isError {
                DispatchQueue.main.async { self.state.lastError = result.text }
            }

            // Assicura che headers siano stati inviati
            sendHeaders()

            // Errore: invia error event e chiudi
            if result.isError {
                finishConnection("error", [
                    "type": "error",
                    "error": ["type": "api_error", "message": result.text],
                ])
                return
            }

            // Fallback: se nessun text block è stato inviato ma abbiamo testo nel result
            if virtualIndex == 0 && !result.text.isEmpty {
                if !messageStartSent {
                    sendSSEEvent("message_start", [
                        "type": "message_start",
                        "message": [
                            "id": msgId,
                            "type": "message",
                            "role": "assistant",
                            "content": [] as [Any],
                            "model": modelName,
                            "stop_reason": NSNull(),
                            "stop_sequence": NSNull(),
                            "usage": [
                                "input_tokens": result.inputTokens,
                                "output_tokens": 1,
                                "cache_creation_input_tokens": 0,
                                "cache_read_input_tokens": 0,
                            ],
                        ] as [String: Any],
                    ])
                }

                sendSSEEvent("content_block_start", [
                    "type": "content_block_start",
                    "index": 0,
                    "content_block": ["type": "text", "text": ""],
                ] as [String: Any])

                sendSSEEvent("ping", ["type": "ping"])

                sendSSEEvent("content_block_delta", [
                    "type": "content_block_delta",
                    "index": 0,
                    "delta": ["type": "text_delta", "text": result.text],
                ] as [String: Any])

                sendSSEEvent("content_block_stop", [
                    "type": "content_block_stop",
                    "index": 0,
                ] as [String: Any])
            }

            // message_delta — usa l'ultimo ricevuto o sintetizza
            let messageDelta = lastMessageDelta ?? [
                "type": "message_delta",
                "delta": ["stop_reason": "end_turn", "stop_sequence": NSNull()] as [String: Any],
                "usage": [
                    "output_tokens": result.outputTokens,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                ],
            ]
            sendSSEEvent("message_delta", messageDelta)

            // message_stop — ultimo evento, chiude la connessione
            finishConnection("message_stop", ["type": "message_stop"])
        }
    }

    // MARK: - Error response helper

    private func sendErrorResponse(on connection: NWConnection, result: CLIResult, stream: Bool) {
        let errorBody: [String: Any] = [
            "type": "error",
            "error": ["type": "api_error", "message": result.text],
        ]

        if stream {
            let headers = "HTTP/1.1 200 OK\r\n"
                + corsHeaders(contentType: "text/event-stream")
                + "Cache-Control: no-cache\r\n"
                + "\r\n"
            guard let jsonData = try? JSONSerialization.data(withJSONObject: errorBody),
                  let jsonStr = String(data: jsonData, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let sse = "event: error\ndata: \(jsonStr)\n\n"
            let responseStr = headers + sse
            if let data = responseStr.data(using: .utf8) {
                connection.send(content: data, contentContext: .finalMessage, isComplete: true,
                               completion: .contentProcessed { _ in connection.cancel() })
            }
        } else {
            let body = try! JSONSerialization.data(withJSONObject: errorBody)
            sendResponse(on: connection, status: 500, statusText: "Internal Server Error",
                        headers: corsHeaders(contentType: "application/json"), body: body)
        }
    }

    // MARK: - HTTP response helpers

    private func corsHeaders(contentType: String? = nil) -> String {
        var h = "Access-Control-Allow-Origin: *\r\n"
        h += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        h += "Access-Control-Allow-Headers: *\r\n"
        if let ct = contentType {
            h += "Content-Type: \(ct)\r\n"
        }
        return h
    }

    private func sendResponse(on connection: NWConnection, status: Int, statusText: String,
                              headers: String, body: Data) {
        let headerStr = "HTTP/1.1 \(status) \(statusText)\r\n"
        + headers
        + "Content-Length: \(body.count)\r\n"
        + "Connection: close\r\n"
        + "\r\n"

        var responseData = headerStr.data(using: .utf8)!
        responseData.append(body)

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
