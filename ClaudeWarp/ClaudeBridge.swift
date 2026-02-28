import Foundation

struct CLIResult {
    let text: String
    let inputTokens: Int
    let outputTokens: Int
    let isError: Bool
}

/// Eventi dal stream NDJSON di claude CLI.
enum StreamEvent {
    case messageStart([String: Any])
    case contentBlockStart(Int, [String: Any])   // original index, full event
    case contentBlockDelta(Int, [String: Any])   // original index, full event
    case contentBlockStop(Int)                    // original index
    case messageDelta([String: Any])
    case messageStop
}

/// Gestione subprocess `claude -p` per chiamate headless.
enum ClaudeBridge {

    // MARK: - Model mapping

    private static let modelMap: [(keyword: String, flag: String)] = [
        ("opus", "opus"),
        ("sonnet", "sonnet"),
        ("haiku", "haiku"),
    ]

    static func resolveModelFlag(_ modelName: String) -> String {
        let lower = modelName.lowercased()
        for (keyword, flag) in modelMap {
            if lower.contains(keyword) { return flag }
        }
        return "sonnet"
    }

    // MARK: - Message formatting

    static func formatMessages(_ messages: [[String: Any]]) -> String {
        guard !messages.isEmpty else { return "" }

        // Single user message: use directly
        if messages.count == 1,
           let role = messages[0]["role"] as? String, role == "user" {
            return extractContent(messages[0]["content"])
        }

        // Multi-turn: format as transcript
        var parts: [String] = []
        for msg in messages {
            let role = msg["role"] as? String ?? "user"
            let content = extractContent(msg["content"])
            if role == "user" {
                parts.append("Human: \(content)")
            } else if role == "assistant" {
                parts.append("Assistant: \(content)")
            }
        }
        return parts.joined(separator: "\n\n")
    }

    private static func extractContent(_ content: Any?) -> String {
        if let str = content as? String { return str }
        if let blocks = content as? [[String: Any]] {
            var textParts: [String] = []
            for block in blocks {
                let type = block["type"] as? String ?? ""
                if type == "text", let text = block["text"] as? String {
                    textParts.append(text)
                } else if type == "tool_result" {
                    let inner = block["content"] ?? ""
                    if let jsonData = try? JSONSerialization.data(withJSONObject: inner),
                       let jsonStr = String(data: jsonData, encoding: .utf8) {
                        textParts.append("[Tool result: \(jsonStr)]")
                    }
                } else if type == "tool_use" {
                    let name = block["name"] as? String ?? "?"
                    let input = block["input"] ?? [String: Any]()
                    if let jsonData = try? JSONSerialization.data(withJSONObject: input),
                       let jsonStr = String(data: jsonData, encoding: .utf8) {
                        textParts.append("[Tool call: \(name)(\(jsonStr))]")
                    }
                }
            }
            return textParts.joined(separator: "\n")
        }
        if let val = content { return "\(val)" }
        return ""
    }

    // MARK: - System prompt

    static func buildSystemPrompt(system: Any?) -> String? {
        var sysText = ""

        if let str = system as? String {
            sysText = str
        } else if let blocks = system as? [[String: Any]] {
            sysText = blocks.compactMap { block -> String? in
                guard (block["type"] as? String) == "text" else { return nil }
                return block["text"] as? String
            }.joined(separator: "\n")
        }

        return sysText.isEmpty ? nil : sysText
    }

    // MARK: - Common environment

    private static func buildEnvironment(configDir: String?) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        env.removeValue(forKey: "CI")
        env["TERM"] = "dumb"
        if env["HOME"] == nil {
            env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        }
        if env["PATH"] == nil {
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        }

        if let configDir = configDir {
            env["CLAUDE_CONFIG_DIR"] = configDir
        }
        let home = env["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        if env["CLAUDE_CONFIG_DIR"] == "\(home)/.claude" {
            env.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        }

        return env
    }

    // MARK: - Allowed tools

    private static let allowedTools = "Bash,Read,Edit,Write,Glob,Grep"

    // MARK: - Call CLI (non-streaming)

    static func call(prompt: String, systemPrompt: String?, modelFlag: String, claudePath: String,
                     configDir: String? = nil, enableTools: Bool = false) async throws -> CLIResult {
        var args = ["-p", "--output-format", "json", "--model", modelFlag, "--no-session-persistence"]

        if enableTools {
            args.append(contentsOf: ["--allowedTools", allowedTools])
            if let sys = systemPrompt {
                args.append(contentsOf: ["--append-system-prompt", sys])
            }
        } else {
            args.append(contentsOf: ["--tools", ""])
            if let sys = systemPrompt {
                args.append(contentsOf: ["--system-prompt", sys])
            }
        }

        let env = buildEnvironment(configDir: configDir)

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                let stdinPipe = Pipe()

                process.executableURL = URL(fileURLWithPath: claudePath)
                process.arguments = args
                process.environment = env
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                process.standardInput = stdinPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: CLIResult(
                        text: "Failed to launch claude CLI: \(error.localizedDescription)",
                        inputTokens: 0, outputTokens: 0, isError: true
                    ))
                    return
                }

                let promptData = prompt.data(using: .utf8) ?? Data()
                stdinPipe.fileHandleForWriting.write(promptData)
                stdinPipe.fileHandleForWriting.closeFile()

                process.waitUntilExit()

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                if process.terminationStatus != 0 {
                    let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let stdout = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let detail = stderr.isEmpty ? (stdout.isEmpty ? "exit code \(process.terminationStatus)" : stdout) : stderr
                    print("[ClaudeWarp] CLI failed: exit=\(process.terminationStatus) stderr=\(stderr.prefix(200)) stdout=\(stdout.prefix(200))")
                    continuation.resume(returning: CLIResult(
                        text: "Claude CLI error: \(detail)",
                        inputTokens: 0, outputTokens: 0, isError: true
                    ))
                    return
                }

                guard let json = try? JSONSerialization.jsonObject(with: stdoutData) as? [String: Any] else {
                    let raw = String(data: stdoutData, encoding: .utf8) ?? ""
                    continuation.resume(returning: CLIResult(
                        text: "Invalid JSON from claude CLI: \(String(raw.prefix(500)))",
                        inputTokens: 0, outputTokens: 0, isError: true
                    ))
                    return
                }

                let result = json["result"] as? String ?? ""
                let usage = json["usage"] as? [String: Any] ?? [:]
                let inputTokens = usage["input_tokens"] as? Int ?? 0
                let outputTokens = usage["output_tokens"] as? Int ?? 0
                let isError = json["is_error"] as? Bool ?? false

                continuation.resume(returning: CLIResult(
                    text: result,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    isError: isError
                ))
            }
        }
    }

    // MARK: - Call CLI (streaming via NDJSON)

    static func callStreaming(
        prompt: String,
        systemPrompt: String?,
        modelFlag: String,
        claudePath: String,
        configDir: String? = nil,
        enableTools: Bool = false,
        onEvent: @escaping (StreamEvent) -> Void
    ) async throws -> CLIResult {
        var args = [
            "-p",
            "--output-format", "stream-json",
            "--verbose",
            "--no-session-persistence",
            "--model", modelFlag,
        ]

        if enableTools {
            args.append(contentsOf: ["--allowedTools", allowedTools])
        } else {
            args.append(contentsOf: ["--tools", ""])
        }

        if let sys = systemPrompt {
            args.append(contentsOf: [enableTools ? "--append-system-prompt" : "--system-prompt", sys])
        }

        let env = buildEnvironment(configDir: configDir)

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                let stdinPipe = Pipe()

                process.executableURL = URL(fileURLWithPath: claudePath)
                process.arguments = args
                process.environment = env
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                process.standardInput = stdinPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: CLIResult(
                        text: "Failed to launch claude CLI: \(error.localizedDescription)",
                        inputTokens: 0, outputTokens: 0, isError: true
                    ))
                    return
                }

                let promptData = prompt.data(using: .utf8) ?? Data()
                stdinPipe.fileHandleForWriting.write(promptData)
                stdinPipe.fileHandleForWriting.closeFile()

                // Read NDJSON from stdout incrementally
                let handle = stdoutPipe.fileHandleForReading
                var buffer = Data()
                var inputTokens = 0
                var outputTokens = 0
                var resultText = ""
                var isError = false
                let newline = Data([0x0A])

                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }  // EOF
                    buffer.append(chunk)

                    while let nlRange = buffer.range(of: newline) {
                        let lineData = Data(buffer[buffer.startIndex..<nlRange.lowerBound])
                        buffer = Data(buffer[nlRange.upperBound...])

                        guard !lineData.isEmpty,
                              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

                        switch json["type"] as? String {
                        case "stream_event":
                            guard let event = json["event"] as? [String: Any],
                                  let eventType = event["type"] as? String else { continue }

                            switch eventType {
                            case "message_start":
                                onEvent(.messageStart(event))
                            case "content_block_start":
                                let index = event["index"] as? Int ?? 0
                                onEvent(.contentBlockStart(index, event))
                            case "content_block_delta":
                                let index = event["index"] as? Int ?? 0
                                onEvent(.contentBlockDelta(index, event))
                            case "content_block_stop":
                                let index = event["index"] as? Int ?? 0
                                onEvent(.contentBlockStop(index))
                            case "message_delta":
                                onEvent(.messageDelta(event))
                            case "message_stop":
                                onEvent(.messageStop)
                            default:
                                break
                            }

                        case "result":
                            resultText = json["result"] as? String ?? ""
                            isError = json["is_error"] as? Bool ?? false
                            if let usage = json["usage"] as? [String: Any] {
                                inputTokens = usage["input_tokens"] as? Int ?? 0
                                outputTokens = usage["output_tokens"] as? Int ?? 0
                            }

                        default:
                            break  // system, assistant, rate_limit_event — skip
                        }
                    }
                }

                process.waitUntilExit()

                if process.terminationStatus != 0 && resultText.isEmpty {
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    resultText = stderr.isEmpty ? "exit code \(process.terminationStatus)" : stderr
                    isError = true
                    print("[ClaudeWarp] CLI streaming failed: exit=\(process.terminationStatus) stderr=\(stderr.prefix(200))")
                }

                continuation.resume(returning: CLIResult(
                    text: resultText,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    isError: isError
                ))
            }
        }
    }
}
