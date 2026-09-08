// ClaudeProvider
// สมองออนไลน์ฝั่ง Claude

import Cocoa

/// ผลของการยิงหนึ่งครั้ง แยก ok/bad เอง เพราะ Result ต้องการ Error ที่ conform จริง
enum ClaudeSend {
    case ok(String)
    case bad(String)
}

final class ClaudeCompanionProvider: CompanionProvider {
    enum Transport {
        case apiKey(String)
        case cli(String)          // path ของ binary `claude`

        var label: String {
            switch self {
            case .apiKey: return "API key"
            case .cli: return "Claude Code CLI"
            }
        }
    }

    static let modelID = "claude-haiku-4-5"

    let transport: Transport
    var brandName: String { "Claude Haiku • \(transport.label)" }
    private let session: URLSession

    /// หา CLI จากที่ที่ติดตั้งกันจริง ไม่พึ่ง PATH เพราะแอป GUI ไม่ได้ inherit shell PATH
    static func findCLI() -> String? {
        let candidates = [
            ProcessInfo.processInfo.environment["PIXELCAT_CLAUDE_CLI"],
            NSString(string: "~/.local/bin/claude").expandingTildeInPath,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            NSString(string: "~/.claude/local/claude").expandingTildeInPath
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    init?() {
        let env = ProcessInfo.processInfo.environment
        let key = (env["ANTHROPIC_API_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            transport = .apiKey(key)
        } else if let cli = Self.findCLI() {
            transport = .cli(cli)
        } else {
            return nil
        }
        session = URLSession(configuration: .ephemeral)
    }

    static func log(_ line: String) {
        guard ProcessInfo.processInfo.environment["PIXELCAT_DEBUG"] != nil else { return }
        FileHandle.standardError.write("CLAUDE \(line)\n".data(using: .utf8)!)
    }

    // MARK: — คุยโต้ตอบ

    func chat(message: String, memory: CompanionMemory, snapshot: CompanionSnapshot,
              completion: @escaping (CompanionChatOutcome) -> Void) {
        let prompt = CompanionPersona.chatPrompt(memory: memory, snapshot: snapshot, message: message)
        send(prompt: prompt, maxTokens: 300) { result in
            switch result {
            case .ok(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                completion(trimmed.isEmpty ? .failure("อั่งเปาไม่มีคำตอบกลับมาเลย ลองใหม่อีกทีนะกริช")
                                           : .reply(trimmed))
            case .bad(let reason):
                completion(.failure(reason))
            }
        }
    }

    // MARK: — ตัดสินใจว่าจะพูดเองไหม

    func decide(memory: CompanionMemory, snapshot: CompanionSnapshot,
                completion: @escaping (CompanionDecision?) -> Void) {
        let prompt = CompanionPersona.decidePrompt(memory: memory, snapshot: snapshot)
        send(prompt: prompt, maxTokens: 120) { result in
            guard case .ok(let text) = result else { completion(nil); return }
            let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, line.uppercased() != "NO", !line.uppercased().hasPrefix("NO ") else {
                completion(nil); return
            }
            completion(CompanionDecision(message: line, mood: "curious", cooldown: 300))
        }
    }

    // MARK: — ท่อส่ง

    private func send(prompt: String, maxTokens: Int,
                      completion: @escaping (ClaudeSend) -> Void) {
        switch transport {
        case .apiKey(let key): sendViaAPI(prompt: prompt, maxTokens: maxTokens, key: key, completion: completion)
        case .cli(let path):   sendViaCLI(prompt: prompt, binary: path, completion: completion)
        }
    }

    private func sendViaAPI(prompt: String, maxTokens: Int, key: String,
                            completion: @escaping (ClaudeSend) -> Void) {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            completion(.bad("URL ของ Claude API ไม่ถูกต้อง")); return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = [
            "model": Self.modelID,
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": prompt]]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            completion(.bad("สร้าง request ไม่สำเร็จ")); return
        }
        request.httpBody = data
        session.dataTask(with: request) { data, response, error in
            let finish: (ClaudeSend) -> Void = { r in DispatchQueue.main.async { completion(r) } }
            if let error {
                Self.log("HTTP transport=\((error as NSError).code)")
                finish(.bad("ต่อไปหา Claude ไม่ได้ (\(error.localizedDescription))")); return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let requestID = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "request-id")
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                Self.log("HTTP status=\(status) decode_failed request_id=\(requestID ?? "-")")
                finish(.bad("อ่านคำตอบจาก Claude ไม่ออก")); return
            }
            guard status == 200 else {
                let err = json["error"] as? [String: Any]
                let type = err?["type"] as? String
                Self.log("HTTP status=\(status) type=\(type ?? "-") request_id=\(requestID ?? "-")")
                if status == 401 || status == 403 {
                    finish(.bad("ANTHROPIC_API_KEY ใช้ไม่ได้ (\(status)) นะกริช")); return
                }
                if status == 429 { finish(.bad("Claude บอกว่าเรียกถี่เกินไป (429) เดี๋ยวลองใหม่นะ")); return }
                finish(.bad("Claude ตอบกลับเป็น error \(status)" + (type.map { " • \($0)" } ?? ""))); return
            }
            let blocks = json["content"] as? [[String: Any]] ?? []
            let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                             .joined(separator: "\n")
            Self.log("HTTP status=200 chars=\(text.count)")
            finish(.ok(text))
        }.resume()
    }

    /// `claude -p` แบบไร้ tool ไร้ MCP — อั่งเปาต้องคุยอย่างเดียว ห้ามไปแตะไฟล์ในเครื่อง
    private func sendViaCLI(prompt: String, binary: String,
                            completion: @escaping (ClaudeSend) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let finish: (ClaudeSend) -> Void = { r in DispatchQueue.main.async { completion(r) } }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = [
                "-p", prompt,
                "--model", Self.modelID,
                "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
                "--disallowed-tools", "Bash,Read,Write,Edit,NotebookEdit,WebFetch,WebSearch,Glob,Grep,Task,Agent"
            ]
            // รันในโฟลเดอร์กลาง ๆ จะได้ไม่หยิบ CLAUDE.md ของโปรเจกต์ไหนมาเป็นบุคลิก
            process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice

            do { try process.run() } catch {
                Self.log("CLI spawn_failed")
                finish(.bad("เรียก claude CLI ไม่สำเร็จ (\(error.localizedDescription))")); return
            }

            // กันค้าง: ถ้าเกิน 90 วิ ให้ฆ่าทิ้งแล้วบอกตรง ๆ ว่า timeout
            let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: timer)

            let outData = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timer.cancel()

            let text = String(data: outData, encoding: .utf8) ?? ""
            let errText = String(data: errData, encoding: .utf8) ?? ""
            Self.log("CLI exit=\(process.terminationStatus) chars=\(text.count) err=\(errData.count)")

            guard process.terminationStatus == 0 else {
                finish(.bad(CompanionChatResilience.claudeCLIFailure(
                    stdout: text, stderr: errText, status: process.terminationStatus
                ))); return
            }
            finish(.ok(text))
        }
    }
}
