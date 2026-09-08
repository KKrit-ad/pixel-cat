// ManusProvider
// สมองออนไลน์ฝั่ง Manus API v2

import Cocoa

/// Manus API v2 adapter. The key is deliberately read only from the environment.
/// Set PIXELCAT_MANUS_API_KEY before launching PixelCat; no key is bundled in the app.
final class ManusCompanionProvider: CompanionProvider {
    let brandName = "Manus"
    private let apiKey: String
    private let session: URLSession

    init?(apiKey: String? = nil) {
        let value = apiKey ?? ProcessInfo.processInfo.environment["PIXELCAT_MANUS_API_KEY"]
            ?? ProcessInfo.processInfo.environment["MANUS_API_KEY"]
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.apiKey = value
        self.session = URLSession(configuration: .ephemeral)
    }

    func decide(memory: CompanionMemory, snapshot: CompanionSnapshot,
                completion: @escaping (CompanionDecision?) -> Void) {
        let prompt = """
        คุณคืออั่งเปา แมวเพศเมียและเพื่อนร่วมโต๊ะของกริช นักพัฒนา software
        ให้ช่วยตัดสินใจว่าน้องควรพูดกับกริชหรือไม่ จาก metadata ต่อไปนี้เท่านั้น
        ห้ามอ้างว่ามองเห็น source code หรืออ่านข้อความส่วนตัว และตอบสั้นเป็นภาษาไทย
        ถ้าไม่ควรพูด ให้ should_speak เป็น false และ message เป็นสตริงว่าง

        active_app=\(snapshot.activeApp)
        user_idle_seconds=\(Int(snapshot.userIdleSeconds))
        working_count=\(snapshot.workingCount)
        waiting_count=\(snapshot.waitingCount)
        attention_count=\(snapshot.attentionCount)
        hottest_context_percent=\(Int(snapshot.hottestContext))
        recent_event=\(snapshot.recentEvent)
        """
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "should_speak": ["type": "boolean"],
                "message": ["type": "string"],
                "mood": ["type": "string", "enum": ["quiet", "curious", "concerned", "happy"]],
                "cooldown_seconds": ["type": "integer"]
            ],
            "required": ["should_speak", "message", "mood", "cooldown_seconds"],
            "additionalProperties": false
        ]
        let body: [String: Any] = [
            "message": ["content": prompt],
            "agent_profile": "manus-1.6-lite",
            "locale": "th",
            "interactive_mode": false,
            "hide_in_task_list": true,
            "share_visibility": "private",
            "structured_output_schema": schema
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let url = URL(string: "https://api.manus.ai/v2/task.create") else {
            DispatchQueue.main.async { completion(nil) }; return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue(apiKey, forHTTPHeaderField: "x-manus-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        session.dataTask(with: request) { [weak self] data, response, _ in
            guard let self, let data, let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let taskID = json["task_id"] as? String else {
                DispatchQueue.main.async { completion(nil) }; return
            }
            self.poll(taskID: taskID, attempts: 0, completion: completion)
        }.resume()
    }

    private func poll(taskID: String, attempts: Int, completion: @escaping (CompanionDecision?) -> Void) {
        guard attempts < 15 else { DispatchQueue.main.async { completion(nil) }; return }
        var components = URLComponents(string: "https://api.manus.ai/v2/task.listMessages")!
        components.queryItems = [URLQueryItem(name: "task_id", value: taskID),
                                 URLQueryItem(name: "order", value: "desc"),
                                 URLQueryItem(name: "limit", value: "20")]
        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "x-manus-api-key")
        request.timeoutInterval = 15
        session.dataTask(with: request) { [weak self] data, response, _ in
            guard let self, let data, let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let messages = json["messages"] as? [[String: Any]] else {
                DispatchQueue.main.async { completion(nil) }; return
            }
            if let result = messages.first(where: { $0["type"] as? String == "structured_output_result" }),
               let output = result["structured_output_result"] as? [String: Any],
               let value = output["value"] as? [String: Any],
               let speak = value["should_speak"] as? Bool {
                guard speak, let message = value["message"] as? String, !message.isEmpty else {
                    let cooldown = max(300, min(3600, value["cooldown_seconds"] as? Int ?? 900))
                    DispatchQueue.main.async { completion(CompanionDecision(message: "", mood: "quiet", cooldown: Double(cooldown))) }
                    return
                }
                let mood = value["mood"] as? String ?? "quiet"
                let cooldown = max(300, min(3600, value["cooldown_seconds"] as? Int ?? 900))
                DispatchQueue.main.async { completion(CompanionDecision(message: message, mood: mood, cooldown: Double(cooldown))) }
                return
            }
            let stopped = messages.contains { event in
                guard event["type"] as? String == "status_update",
                      let status = event["status_update"] as? [String: Any] else { return false }
                return status["agent_status"] as? String == "stopped"
            }
            if stopped { DispatchQueue.main.async { completion(nil) }; return }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0) {
                self.poll(taskID: taskID, attempts: attempts + 1, completion: completion)
            }
        }.resume()
    }

    // MARK: — คุยกับอั่งเปาแบบโต้ตอบ

    /// error ของ API ที่เก็บรายละเอียดพอวินิจฉัยได้ โดยไม่แตะ key
    enum ManusFailure: Error {
        case http(status: Int, code: String?, message: String?, requestID: String?)
        case transport(String)
        case timeout
        case decode

        var logText: String {
            switch self {
            case .http(let status, let code, let message, let requestID):
                return "status=\(status) code=\(code ?? "-") request_id=\(requestID ?? "-") message=\(message ?? "-")"
            case .transport(let detail): return "transport=\(detail)"
            case .timeout: return "timeout"
            case .decode: return "decode"
            }
        }

        var userText: String {
            switch self {
            case .http(let status, let code, _, _):
                if status == 401 || status == 403 {
                    return "API key ของ Manus ใช้ไม่ได้ (\(status)) ลองตั้ง PIXELCAT_MANUS_API_KEY ใหม่นะกริช"
                }
                if status == 429 { return "Manus บอกว่าเรียกถี่เกินไป (429) เดี๋ยวลองใหม่นะ" }
                if status == 404 { return "ห้องคุยเดิมหายไปแล้ว ลองสั่ง \"รีเซ็ตห้องคุยกับอั่งเปา\" แล้วคุยใหม่นะ" }
                return "Manus ตอบกลับเป็น error \(status)" + (code.map { " • \($0)" } ?? "")
            case .transport(let detail): return "ต่อไปหา Manus ไม่ได้ (\(detail))"
            case .timeout: return "อั่งเปารอ Manus นานเกินไปแล้ว ยังไม่มีคำตอบกลับมาเลย"
            case .decode: return "อ่านคำตอบจาก Manus ไม่ออก รูปแบบข้อมูลไม่ตรงที่คาด"
            }
        }
    }

    static let chatTaskKey = "pixelcat.manus.chatTaskID"

    static func resetChatTask() { UserDefaults.standard.removeObject(forKey: chatTaskKey) }

    /// log ปลอดภัย: ไม่มี key ไม่มี header ไม่มีเนื้อข้อความ
    static func log(_ line: String) {
        guard ProcessInfo.processInfo.environment["PIXELCAT_DEBUG"] != nil else { return }
        FileHandle.standardError.write("MANUS \(line)\n".data(using: .utf8)!)
    }

    private func perform(_ request: URLRequest, path: String,
                         completion: @escaping (Result<[String: Any], ManusFailure>) -> Void) {
        session.dataTask(with: request) { data, response, error in
            let finish: (Result<[String: Any], ManusFailure>) -> Void = { result in
                DispatchQueue.main.async { completion(result) }
            }
            if let error {
                Self.log("HTTP path=\(path) transport_error=\((error as NSError).code)")
                finish(.failure(.transport("\((error as NSError).code)"))); return
            }
            guard let http = response as? HTTPURLResponse else {
                Self.log("HTTP path=\(path) no_response"); finish(.failure(.decode)); return
            }
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            guard (200..<300).contains(http.statusCode) else {
                let err = json?["error"] as? [String: Any]
                let code = err?["code"] as? String ?? json?["code"] as? String
                let message = err?["message"] as? String ?? json?["message"] as? String
                let requestID = json?["request_id"] as? String
                    ?? http.value(forHTTPHeaderField: "x-request-id")
                Self.log("HTTP path=\(path) status=\(http.statusCode) code=\(code ?? "-") request_id=\(requestID ?? "-")")
                finish(.failure(.http(status: http.statusCode, code: code, message: message, requestID: requestID)))
                return
            }
            guard let json else {
                Self.log("HTTP path=\(path) status=\(http.statusCode) body_not_json")
                finish(.failure(.decode)); return
            }
            Self.log("HTTP path=\(path) status=\(http.statusCode)")
            finish(.success(json))
        }.resume()
    }

    private func postJSON(path: String, body: [String: Any],
                          completion: @escaping (Result<[String: Any], ManusFailure>) -> Void) {
        guard let url = URL(string: "https://api.manus.ai\(path)"),
              let data = try? JSONSerialization.data(withJSONObject: body) else {
            DispatchQueue.main.async { completion(.failure(.decode)) }; return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(apiKey, forHTTPHeaderField: "x-manus-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        perform(request, path: path, completion: completion)
    }

    /// ดึง event ของ task ออกมาเป็น array เดียว รองรับทั้ง `messages` และ `data.messages`
    private func listMessages(taskID: String,
                              completion: @escaping (Result<[[String: Any]], ManusFailure>) -> Void) {
        var components = URLComponents(string: "https://api.manus.ai/v2/task.listMessages")!
        components.queryItems = [URLQueryItem(name: "task_id", value: taskID),
                                 URLQueryItem(name: "order", value: "desc"),
                                 URLQueryItem(name: "limit", value: "50")]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        request.setValue(apiKey, forHTTPHeaderField: "x-manus-api-key")
        perform(request, path: "/v2/task.listMessages") { result in
            switch result {
            case .failure(let failure): completion(.failure(failure))
            case .success(let json):
                let nested = (json["data"] as? [String: Any])?["messages"] as? [[String: Any]]
                guard let events = json["messages"] as? [[String: Any]] ?? nested else {
                    Self.log("LIST decode_failed keys=\(json.keys.sorted().joined(separator: ","))")
                    completion(.failure(.decode)); return
                }
                completion(.success(events))
            }
        }
    }

    func chat(message: String, memory: CompanionMemory, snapshot: CompanionSnapshot,
              completion: @escaping (CompanionChatOutcome) -> Void) {
        let content = CompanionPersona.chatPrompt(memory: memory, snapshot: snapshot, message: message)
        guard let savedTask = UserDefaults.standard.string(forKey: Self.chatTaskKey) else {
            createChatTask(content: content, completion: completion); return
        }
        // จับ baseline ของ event id ก่อนส่ง จะได้ไม่หยิบคำตอบเก่ามาใช้ซ้ำ (timestamp อย่างเดียวเชื่อไม่ได้)
        listMessages(taskID: savedTask) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let events):
                let baseline = Set(events.compactMap { $0["id"] as? String })
                Self.log("BASELINE events=\(events.count) ids=\(baseline.count)")
                self.sendChat(taskID: savedTask, content: content, baseline: baseline, completion: completion)
            case .failure(let failure):
                Self.log("BASELINE failed \(failure.logText) → สร้าง task ใหม่")
                Self.resetChatTask()
                self.createChatTask(content: content, completion: completion)
            }
        }
    }

    private func createChatTask(content: String, completion: @escaping (CompanionChatOutcome) -> Void) {
        // interactive_mode ต้องเป็น true ไม่งั้น task จะจบตัวเองแล้ว sendMessage รอบถัดไปจะพัง
        let body: [String: Any] = [
            "message": ["content": content],
            "agent_profile": "manus-1.6-lite",
            "locale": "th",
            "interactive_mode": true,
            "hide_in_task_list": true,
            "share_visibility": "private",
            "title": "PixelCat • อั่งเปาคุยกับกริช"
        ]
        postJSON(path: "/v2/task.create", body: body) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let failure):
                completion(.failure(failure.userText))
            case .success(let json):
                let taskID = json["task_id"] as? String
                    ?? (json["data"] as? [String: Any])?["task_id"] as? String
                    ?? json["id"] as? String
                Self.log("CREATE task_id_present=\(taskID != nil)")
                guard let taskID else { completion(.failure(ManusFailure.decode.userText)); return }
                UserDefaults.standard.set(taskID, forKey: Self.chatTaskKey)
                // task เพิ่งสร้าง ยังไม่มี event เก่า จึงไม่ต้องมี baseline
                self.pollForReply(taskID: taskID, baseline: [],
                                  deadline: Date().addingTimeInterval(120),
                                  attempt: 0, sawStopped: 0, completion: completion)
            }
        }
    }

    private func sendChat(taskID: String, content: String, baseline: Set<String>,
                          completion: @escaping (CompanionChatOutcome) -> Void) {
        let body: [String: Any] = ["task_id": taskID,
                                   "message": ["content": content],
                                   "agent_profile": "manus-1.6-lite"]
        postJSON(path: "/v2/task.sendMessage", body: body) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.pollForReply(taskID: taskID, baseline: baseline,
                                  deadline: Date().addingTimeInterval(120),
                                  attempt: 0, sawStopped: 0, completion: completion)
            case .failure(let failure):
                // task เดิมเสีย/จบไปแล้ว → ทิ้งแล้วเปิดห้องใหม่ให้อัตโนมัติ หนึ่งครั้ง
                if case .http(let status, _, _, _) = failure, (400..<500).contains(status) {
                    Self.log("SEND failed \(failure.logText) → recreate task")
                    Self.resetChatTask()
                    self.createChatTask(content: content, completion: completion)
                } else {
                    completion(.failure(failure.userText))
                }
            }
        }
    }

    private func pollForReply(taskID: String, baseline: Set<String>, deadline: Date,
                              attempt: Int, sawStopped: Int,
                              completion: @escaping (CompanionChatOutcome) -> Void) {
        guard Date() < deadline else {
            Self.log("POLL give_up attempt=\(attempt)")
            completion(.failure(ManusFailure.timeout.userText)); return
        }
        listMessages(taskID: taskID) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let failure):
                completion(.failure(failure.userText))
            case .success(let events):
                let types = events.compactMap { $0["type"] as? String }
                Self.log("POLL attempt=\(attempt) count=\(events.count) types=\(types.joined(separator: ","))")
                // event ใหม่ = id ที่ยังไม่เคยเห็นตอนก่อนส่ง (desc order ตัวแรกคือใหม่สุด)
                let fresh = events.filter { event in
                    guard let id = event["id"] as? String else { return false }
                    return !baseline.contains(id)
                }
                for event in fresh where event["type"] as? String == "assistant_message" {
                    guard let text = Self.assistantText(from: event), !text.isEmpty else { continue }
                    Self.log("ASSISTANT candidate id=\(event["id"] as? String ?? "-") fresh=true content_length=\(text.count)")
                    completion(.reply(text)); return
                }
                let errored = fresh.contains { event in
                    guard event["type"] as? String == "status_update",
                          let status = event["status_update"] as? [String: Any] else { return false }
                    return status["agent_status"] as? String == "error"
                }
                if errored {
                    Self.log("POLL agent_status=error")
                    completion(.failure("Manus แจ้งว่ารอบนี้ทำงานผิดพลาด ลองถามใหม่อีกทีนะกริช")); return
                }
                let stopped = fresh.contains { event in
                    guard event["type"] as? String == "status_update",
                          let status = event["status_update"] as? [String: Any] else { return false }
                    return status["agent_status"] as? String == "stopped"
                }
                // stopped แล้วยังไม่มีข้อความ → เผื่ออีก 2 รอบให้ assistant event ตามมา
                let stoppedCount = stopped ? sawStopped + 1 : sawStopped
                if stoppedCount > 2 {
                    Self.log("POLL stopped_without_reply")
                    completion(.failure("Manus จบรอบแล้วแต่ไม่มีข้อความตอบกลับมา")); return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.pollForReply(taskID: taskID, baseline: baseline, deadline: deadline,
                                      attempt: attempt + 1, sawStopped: stoppedCount, completion: completion)
                }
            }
        }
    }

    /// content อาจมาเป็น String ตรง ๆ หรือเป็น array ของ block ตาม schema
    private static func assistantText(from event: [String: Any]) -> String? {
        guard let assistant = event["assistant_message"] as? [String: Any] else {
            return event["content"] as? String
        }
        if let text = assistant["content"] as? String { return text }
        if let blocks = assistant["content"] as? [[String: Any]] {
            let joined = blocks.compactMap { $0["text"] as? String ?? $0["content"] as? String }
                .joined(separator: "\n")
            return joined.isEmpty ? nil : joined
        }
        return assistant["text"] as? String
    }
}
