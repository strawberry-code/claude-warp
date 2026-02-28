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
            print("[ClaudeWarp] ⚠ 404 Not Found: \(request.method) \(request.path)")
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
        let systemPrompt = ClaudeBridge.buildSystemPrompt(system: system, tools: tools)
        let effectiveModel = state.selectedModel.isEmpty ? modelName : state.selectedModel
        let modelFlag = ClaudeBridge.resolveModelFlag(effectiveModel)
        let claudePath = state.claudePath
        let configDir = state.activeEnvironment?.configDir

        let hasTools = tools != nil && !(tools!.isEmpty)

        let envName = state.activeEnvironment?.name ?? "default"
        print("[ClaudeWarp] env=\(envName) | model=\(modelName) → --model \(modelFlag) | messages=\(messages.count) | tools=\(tools?.count ?? 0) | stream=\(stream)")

        Task {
            let startTime = Date()
            let result: CLIResult
            do {
                result = try await ClaudeBridge.call(prompt: prompt, systemPrompt: systemPrompt, modelFlag: modelFlag, claudePath: claudePath, configDir: configDir)
            } catch {
                result = CLIResult(text: "Bridge error: \(error.localizedDescription)", inputTokens: 0, outputTokens: 0, isError: true)
            }

            let elapsed = Date().timeIntervalSince(startTime)
            print("[ClaudeWarp] claude responded in \(String(format: "%.1f", elapsed))s | error=\(result.isError)")

            if result.isError {
                DispatchQueue.main.async { self.state.lastError = result.text }
            }

            let msgId = "msg_proxy_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))"

            // Parse tool_use blocks if tools were provided
            let contentBlocks: [[String: Any]]
            if hasTools {
                contentBlocks = ClaudeBridge.parseToolUse(from: result.text)
            } else {
                contentBlocks = [["type": "text", "text": result.text]]
            }

            let hasToolUse = contentBlocks.contains { ($0["type"] as? String) == "tool_use" }
            let stopReason = hasToolUse ? "tool_use" : "end_turn"

            if result.isError {
                let errorBody: [String: Any] = [
                    "type": "error",
                    "error": ["type": "api_error", "message": result.text]
                ]
                if stream {
                    let eventData = try! JSONSerialization.data(withJSONObject: errorBody)
                    let event = "event: error\ndata: \(String(data: eventData, encoding: .utf8)!)\n\n"
                    self.sendSSE(on: connection, events: event)
                } else {
                    let body = try! JSONSerialization.data(withJSONObject: errorBody)
                    self.sendResponse(on: connection, status: 500, statusText: "Internal Server Error",
                                    headers: self.corsHeaders(contentType: "application/json"), body: body)
                }
                return
            }

            if stream {
                self.sendStreamingResponse(on: connection, msgId: msgId, modelName: modelName,
                                          contentBlocks: contentBlocks, stopReason: stopReason,
                                          inputTokens: result.inputTokens, outputTokens: result.outputTokens)
            } else {
                let response: [String: Any] = [
                    "id": msgId,
                    "type": "message",
                    "role": "assistant",
                    "content": contentBlocks,
                    "model": modelName,
                    "stop_reason": stopReason,
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

    // MARK: - SSE streaming response (Anthropic Messages API spec)

    private func sendStreamingResponse(on connection: NWConnection, msgId: String, modelName: String,
                                       contentBlocks: [[String: Any]], stopReason: String,
                                       inputTokens: Int, outputTokens: Int) {
        var events = ""

        // 1. message_start — usage.output_tokens inizia a 1 come da spec
        events += sseEvent("message_start", data: [
            "type": "message_start",
            "message": [
                "id": msgId,
                "type": "message",
                "role": "assistant",
                "content": [] as [Any],
                "model": modelName,
                "stop_reason": NSNull(),
                "stop_sequence": NSNull(),
                "usage": ["input_tokens": inputTokens, "output_tokens": 1, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0],
            ] as [String: Any],
        ])

        // 2. content blocks
        for (idx, block) in contentBlocks.enumerated() {
            let blockType = block["type"] as? String ?? "text"

            if blockType == "text" {
                let text = block["text"] as? String ?? ""

                // content_block_start
                events += sseEvent("content_block_start", data: [
                    "type": "content_block_start",
                    "index": idx,
                    "content_block": ["type": "text", "text": ""],
                ] as [String: Any])

                // ping dopo il primo content_block_start (come da spec)
                if idx == 0 {
                    events += sseEvent("ping", data: ["type": "ping"])
                }

                // content_block_delta — chunk da ~80 char (simula streaming realistico)
                let chunkSize = 80
                var i = text.startIndex
                while i < text.endIndex {
                    let end = text.index(i, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
                    let chunk = String(text[i..<end])
                    events += sseEvent("content_block_delta", data: [
                        "type": "content_block_delta",
                        "index": idx,
                        "delta": ["type": "text_delta", "text": chunk],
                    ] as [String: Any])
                    i = end
                }

                // content_block_stop
                events += sseEvent("content_block_stop", data: [
                    "type": "content_block_stop",
                    "index": idx,
                ] as [String: Any])

            } else if blockType == "tool_use" {
                // content_block_start per tool_use
                events += sseEvent("content_block_start", data: [
                    "type": "content_block_start",
                    "index": idx,
                    "content_block": [
                        "type": "tool_use",
                        "id": block["id"] as? String ?? "",
                        "name": block["name"] as? String ?? "",
                        "input": [String: Any](),
                    ] as [String: Any],
                ] as [String: Any])

                // primo delta vuoto come da spec
                events += sseEvent("content_block_delta", data: [
                    "type": "content_block_delta",
                    "index": idx,
                    "delta": ["type": "input_json_delta", "partial_json": ""],
                ] as [String: Any])

                // input_json_delta con il JSON completo
                let input = block["input"] ?? [String: Any]()
                let inputJson = (try? JSONSerialization.data(withJSONObject: input))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                events += sseEvent("content_block_delta", data: [
                    "type": "content_block_delta",
                    "index": idx,
                    "delta": ["type": "input_json_delta", "partial_json": inputJson],
                ] as [String: Any])

                // content_block_stop
                events += sseEvent("content_block_stop", data: [
                    "type": "content_block_stop",
                    "index": idx,
                ] as [String: Any])
            }
        }

        // 3. message_delta — usage.output_tokens è cumulativo
        events += sseEvent("message_delta", data: [
            "type": "message_delta",
            "delta": ["stop_reason": stopReason, "stop_sequence": NSNull()] as [String: Any],
            "usage": ["output_tokens": outputTokens, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0],
        ] as [String: Any])

        // 4. message_stop
        events += sseEvent("message_stop", data: ["type": "message_stop"])

        sendSSE(on: connection, events: events)
    }

    private func sseEvent(_ event: String, data: [String: Any]) -> String {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data),
              let jsonStr = String(data: jsonData, encoding: .utf8) else { return "" }
        return "event: \(event)\ndata: \(jsonStr)\n\n"
    }

    /// Invia la risposta SSE completa e chiude la connessione con TCP FIN (non RST).
    private func sendSSE(on connection: NWConnection, events: String) {
        let headers = corsHeaders(contentType: "text/event-stream")
        + "Cache-Control: no-cache\r\n"

        let responseStr = "HTTP/1.1 200 OK\r\n\(headers)\r\n\(events)"
        let responseData = responseStr.data(using: .utf8)!

        // isComplete: true → TCP FIN graceful (non RST da cancel)
        connection.send(content: responseData, contentContext: .finalMessage, isComplete: true,
                       completion: .contentProcessed { _ in
            connection.cancel()
        })
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
