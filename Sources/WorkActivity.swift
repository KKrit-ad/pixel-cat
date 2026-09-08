// WorkActivity
// อ่านกิจกรรม coding/build/test จาก Codex และ Claude Code

import Cocoa

/// สถานะกิจกรรมจากหลาย adapter (Codex rollout / Claude hook) ที่ภาษากายต้องรู้จัก
enum WorkActivityKind: String, Hashable {
    case idle, coding, build, testing, testPassed, testFailed, permission

    var priority: Int {
        switch self {
        case .idle: return 0
        case .testPassed: return 1
        case .coding: return 2
        case .build: return 3
        case .testing: return 4
        case .testFailed: return 5
        case .permission: return 6
        }
    }
}

struct WorkActivitySignal: Equatable {
    let kind: WorkActivityKind
    let fingerprint: String

    static let idle = WorkActivitySignal(kind: .idle, fingerprint: "")
}

/// Deep module: ซ่อนศัพท์และรูปแบบ event ของ Codex/Claude หลัง interface ที่คืน signal เดียว
enum BuildTestAwareness {
    private struct PendingCommand {
        let kind: WorkActivityKind
        let fingerprint: String
    }

    static func classify(state: String, message: String,
                         fingerprint: String) -> WorkActivitySignal {
        let state = state.lowercased()
        let text = message.lowercased()
        let combined = state + " " + text

        if ["permission", "approval", "approve", "ask_permission"].contains(state)
            || ((["input", "ask", "waiting"].contains(state)) && containsPermission(combined)) {
            return WorkActivitySignal(kind: .permission, fingerprint: fingerprint)
        }
        if ["test_fail", "test_failed", "tests_failed"].contains(state)
            || ((["fail", "failed", "error"].contains(state)) && containsTest(combined)) {
            return WorkActivitySignal(kind: .testFailed, fingerprint: fingerprint)
        }
        if ["test_pass", "test_passed", "tests_passed"].contains(state)
            || ((["done", "idle", "completed"].contains(state))
                && containsTest(combined) && containsSuccess(combined)) {
            return WorkActivitySignal(kind: .testPassed, fingerprint: fingerprint)
        }
        if ["coding", "edit", "editing", "patch"].contains(state)
            || ((["working", "busy", "inprogress"].contains(state)) && containsEditing(combined)) {
            return WorkActivitySignal(kind: .coding, fingerprint: fingerprint)
        }
        if ["test", "testing", "tests"].contains(state)
            || ((["working", "busy", "inprogress"].contains(state)) && containsTest(combined)) {
            return WorkActivitySignal(kind: .testing, fingerprint: fingerprint)
        }
        if ["build", "building"].contains(state)
            || ((["working", "busy", "inprogress"].contains(state)) && containsBuild(combined)) {
            return WorkActivitySignal(kind: .build, fingerprint: fingerprint)
        }
        return .idle
    }

    /// อ่านเฉพาะท้าย rollout และคืนสิ่งที่ task กำลังทำล่าสุด โดยไม่เปิดเผยข้อความออกจากเครื่อง
    static func codexRollout(path: String, turnState: String) -> WorkActivitySignal {
        guard !path.isEmpty,
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return .idle
        }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return .idle }
        let cap: UInt64 = 768 * 1024
        let start = size > cap ? size - cap : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return .idle }
        return codexRollout(data: data, turnState: turnState, skippedPrefix: start > 0)
    }

    /// Data overload เป็น seam สำหรับ simulation โดยไม่ต้องสร้างฐานข้อมูลหรือไฟล์จริง
    static func codexRollout(data: Data, turnState: String,
                            skippedPrefix: Bool = false) -> WorkActivitySignal {
        var lines = data.split(separator: 0x0A)
        if skippedPrefix, !lines.isEmpty { lines.removeFirst() }
        var pending: [String: PendingCommand] = [:]
        var continuation: PendingCommand?
        var latest = WorkActivitySignal.idle

        for line in lines {
            guard let root = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = root["payload"] as? [String: Any],
                  let type = payload["type"] as? String else { continue }
            switch type {
            case "custom_tool_call":
                let callID = (payload["call_id"] as? String) ?? (payload["id"] as? String) ?? UUID().uuidString
                let input = payload["input"] as? String ?? ""
                if input.contains("tools.write_stdin"), let active = continuation {
                    pending[callID] = active
                    latest = WorkActivitySignal(kind: active.kind, fingerprint: active.fingerprint)
                    continue
                }
                let baseKind: WorkActivityKind
                if input.contains("tools.apply_patch") {
                    baseKind = .coding
                } else if input.contains("tools.exec_command") {
                    baseKind = commandKind(input)
                } else {
                    latest = .idle
                    continue
                }
                guard baseKind != .idle else {
                    latest = .idle
                    continue
                }
                let command = PendingCommand(kind: baseKind, fingerprint: callID)
                pending[callID] = command
                continuation = command
                latest = WorkActivitySignal(
                    kind: containsPermission(input.lowercased()) ? .permission : baseKind,
                    fingerprint: callID
                )

            case "custom_tool_call_output":
                let callID = (payload["call_id"] as? String) ?? (payload["id"] as? String) ?? ""
                guard let command = pending.removeValue(forKey: callID) else { continue }
                let output = flatten(payload["output"]).lowercased()
                if output.contains("script running") || output.contains("session_id=") {
                    continuation = command
                    latest = WorkActivitySignal(kind: command.kind, fingerprint: command.fingerprint)
                } else if command.kind == .testing {
                    continuation = nil
                    latest = WorkActivitySignal(
                        kind: containsFailure(output) ? .testFailed : .testPassed,
                        fingerprint: command.fingerprint
                    )
                } else if command.kind == .coding {
                    continuation = nil
                    latest = WorkActivitySignal(kind: .coding, fingerprint: command.fingerprint)
                } else {
                    continuation = nil
                    latest = .idle
                }

            default:
                continue
            }
        }

        // ผลทดสอบมีความหมายแม้ turn เพิ่ง completed; กิจกรรมที่ยังรันต้องอาศัย inProgress
        if latest.kind == .coding || latest.kind == .build
            || latest.kind == .testing || latest.kind == .permission {
            let running = ["inprogress", "working", "busy"].contains(turnState.lowercased())
            return running ? latest : .idle
        }
        return latest
    }

    private static func commandKind(_ input: String) -> WorkActivityKind {
        let text = input.lowercased()
        guard !text.contains("tools.apply_patch") else { return .idle }
        let testCommands = [
            "zsh check-", "./check-", "for f in check-", "swift test", "pytest",
            "npm test", "npm run test", "pnpm test", "yarn test", "cargo test",
            "go test", "xcodebuild test", "ctest"
        ]
        if testCommands.contains(where: text.contains) { return .testing }
        let buildCommands = [
            "./build.sh", "xcodebuild build", "swift build", "swiftc ",
            "npm run build", "pnpm build", "yarn build", "cargo build",
            "gradle build", "make build"
        ]
        if buildCommands.contains(where: text.contains) { return .build }
        return .idle
    }

    private static func containsPermission(_ text: String) -> Bool {
        ["require_escalated", "permission", "approval", "approve", "allow this",
         "อนุญาต", "ขอสิทธิ์"].contains(where: text.contains)
    }

    private static func containsTest(_ text: String) -> Bool {
        ["test", "pytest", "xctest", "vitest", "jest", "rspec", "check-",
         "ทดสอบ"].contains(where: text.contains)
    }

    private static func containsBuild(_ text: String) -> Bool {
        ["build", "compile", "swiftc", "xcodebuild", "gradle", "คอมไพล์"].contains(where: text.contains)
    }

    private static func containsEditing(_ text: String) -> Bool {
        ["coding", "editing", "edit file", "apply patch", "apply_patch", "แก้โค้ด",
         "แก้ไฟล์"].contains(where: text.contains)
    }

    private static func containsSuccess(_ text: String) -> Bool {
        ["pass", "passed", "success", "completed", "exit=0", "ผ่าน"].contains(where: text.contains)
    }

    private static func containsFailure(_ text: String) -> Bool {
        let explicit = ["script failed", "fail:", "build failed", "test failed", "tests failed",
                        "exit=1", "exit_code\":1", "fatal error"]
        if explicit.contains(where: text.contains) { return true }
        let patterns = [#"\b[1-9][0-9]*\s+(failed|failing)\b"#,
                        #"\bfailures?\s*:\s*[1-9][0-9]*\b"#,
                        #"\bexit(_code)?\s*[=:]\s*[1-9][0-9]*\b"#]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    private static func flatten(_ value: Any?) -> String {
        guard let value else { return "" }
        if let string = value as? String { return string }
        if let array = value as? [Any] { return array.map(flatten).joined(separator: " ") }
        if let object = value as? [String: Any] { return object.values.map(flatten).joined(separator: " ") }
        return String(describing: value)
    }
}
