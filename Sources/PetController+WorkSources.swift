// PetController+WorkSources
// อ่านสถานะงานจริงจาก Codex rollout (SQLite) และ event ของ Claude Code
//
// แยกออกมาเพราะเป็นการ "อ่านโลกภายนอก" ล้วน ๆ ไม่ใช่แอนิเมชันหรือสถานะของน้อง

import Cocoa
import SQLite3

extension PetController {

    func pollInbox(_ dt: Double) {
        inboxPoll -= dt
        guard inboxPoll <= 0 else { return }
        inboxPoll = 0.4
        guard let attr = try? FileManager.default.attributesOfItem(atPath: INBOX),
              let mod = attr[.modificationDate] as? Date else { return }
        if let seen = inboxStamp, mod <= seen { return }
        let first = inboxStamp == nil
        inboxStamp = mod
        if first { return }                       // ครั้งแรกแค่จำเวลาไว้ ไม่ต้องพูดของเก่า
        guard let raw = try? String(contentsOfFile: INBOX, encoding: .utf8) else { return }
        let line = raw.split(separator: "\n").last.map(String.init) ?? ""
        let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
        guard let event = parts.first, !event.isEmpty else { return }
        let msg = parts.count > 1 ? parts[1] : ""
        let ev = event.trimmingCharacters(in: .whitespaces)
        if ProcessInfo.processInfo.environment["PIXELCAT_DEBUG"] != nil {
            FileHandle.standardError.write("INBOX event=\(ev) msg=\(msg)\n".data(using: .utf8)!)
        }
        handleClaude(event: ev, message: msg)
    }

    func handleClaude(event: String, message: String) {
        guard !held, focusPhase == .idle else {
            // อ่าน stamp ของไฟล์แล้วจึงต้องเก็บ event ไว้ ไม่เช่นนั้น hook ที่เข้าระหว่าง Focus จะหายถาวร
            let deferred = DeferredClaudeEvent(event: event, message: message)
            if deferredClaudeEvents.last?.event != event
                || deferredClaudeEvents.last?.message != message {
                deferredClaudeEvents.append(deferred)
            }
            return
        }
        let activity = BuildTestAwareness.classify(
            state: event, message: message,
            fingerprint: "claude-inbox:\(event):\(message)"
        )
        if activity.kind != .idle {
            playBuildTestAnimation(activity.kind)
            let fallback: String
            switch activity.kind {
            case .coding: fallback = "กำลังแก้โค้ดอยู่ • แป๊บเดียวนะ"
            case .build: fallback = "กำลัง build อยู่นะ 🔧"
            case .testing: fallback = "กำลังรัน test • ลุ้นอยู่"
            case .testPassed: fallback = "test ผ่านแล้ว!"
            case .testFailed: fallback = "test พังแล้ว • น้องเก็บ error ไว้ให้"
            case .permission: fallback = "มี permission รอให้กดอยู่นะ"
            case .idle: fallback = ""
            }
            say(message.isEmpty ? fallback : message,
                for: activity.kind == .permission ? 6.0 : 3.8)
            return
        }
        let fallback: String
        switch event {
        case "busy":
            fallback = "ทำงานอยู่นะ"
            setState("walk", duration: Double.random(in: 3...6))
        case "done":
            fallback = "เสร็จแล้วน้า~"
            playWorkEmotion(.done)
        case "ask":
            fallback = "มาดูหน่อยสิ"
            playWorkEmotion(.input)
        case "fail":
            fallback = "พังแล้ว!"
            playWorkEmotion(.failed)
        default: return
        }
        say(message.isEmpty ? fallback : message, for: event == "ask" ? 5.0 : 3.4)
    }

    func flushDeferredClaudeEvent() {
        guard focusPhase == .idle, !held, activeWorkNotice == nil,
              activeContextRescue == nil,
              speakFor <= 0, !deferredClaudeEvents.isEmpty else { return }
        let deferred = deferredClaudeEvents.removeFirst()
        handleClaude(event: deferred.event, message: deferred.message)
    }

    /// รันสคริปต์ตรวจ (ลง time / งานค้าง) — ต้องให้แอปเป็นคนรัน ไม่ใช่ launchd
    /// เพราะ macOS กัน background process ไม่ให้อ่าน ~/Desktop
    func runCheck(_ dt: Double) {
        checkIn -= dt
        guard checkIn <= 0 else { return }
        checkIn = 900                                    // ทุก 15 นาที
        let path = NSString(string: "~/.pixelcat/check.sh").expandingTildeInPath
        guard FileManager.default.isExecutableFile(atPath: path) else { return }
        DispatchQueue.global(qos: .utility).async {
            let t = Process()
            t.executableURL = URL(fileURLWithPath: "/bin/zsh")
            t.arguments = [path]
            try? t.run()
        }
    }

    /// นั่งทำงานติดกันนานเกินไป ให้น้องมายืดตัวเตือน
    /// นับเฉพาะตอนมีการขยับเมาส์/คีย์ ถ้าลุกไปแล้ว (ว่างเกิน 3 นาที) ให้รีเซ็ต
    func breakReminder(_ dt: Double) {
        guard focusPhase == .idle else { return }
        let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .init(rawValue: ~0)!)
        if idle > 180 { activeStreak = 0; breakNudged = false; return }
        guard idle < 60 else { return }
        activeStreak += dt
        if activeStreak > 50 * 60 && !breakNudged {
            breakNudged = true
            setState("stretch", duration: 5) { [weak self] in self?.pickIdle() }
            say("นั่งมา 50 นาทีแล้ว ลุกยืดหน่อย", for: 6)
        }
    }

    func sqliteText(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let raw = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: raw)
    }

    /// อ่านสถานะ turn ล่าสุดของ Codex โดยเปิดฐานข้อมูลแบบ read-only เท่านั้น
    func latestCodexTurnStates() -> [String: String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(CODEX_HISTORY_DB, &db,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close(db) }
            return [:]
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)

        let sql = """
            SELECT turn.thread_id, turn.status
            FROM thread_turns AS turn
            JOIN (
                SELECT thread_id, MAX(rollout_ordinal) AS ordinal
                FROM thread_turns GROUP BY thread_id
            ) AS latest
              ON latest.thread_id = turn.thread_id
             AND latest.ordinal = turn.rollout_ordinal
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return [:] }
        defer { sqlite3_finalize(statement) }

        var states: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            states[sqliteText(statement, 0)] = sqliteText(statement, 1)
        }
        return states
    }

    /// อ่าน token_count ล่าสุดจากท้าย rollout เท่านั้น (สูงสุด 256 KiB)
    /// ใช้ window ที่ Codex บันทึกมากับ event จึงไม่ต้อง hard-code context size ของโมเดล
    func codexContextPercent(rolloutPath: String) -> Double {
        guard !rolloutPath.isEmpty else { return 0 }
        let attributes = try? FileManager.default.attributesOfItem(atPath: rolloutPath)
        let modified = attributes?[.modificationDate] as? Date ?? .distantPast
        let fileSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        if let cached = codexContextCache[rolloutPath],
           cached.modified == modified, cached.size == fileSize {
            return cached.percent
        }
        guard
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: rolloutPath)) else {
            return 0
        }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return 0 }
        let cap: UInt64 = 512 * 1024
        let start = size > cap ? size - cap : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return 0 }
        var lines = data.split(separator: 0x0A)
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        for line in lines.reversed() {
            guard let root = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = root["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let usage = info["last_token_usage"] as? [String: Any],
                  let used = usage["total_tokens"] as? NSNumber,
                  let window = info["model_context_window"] as? NSNumber,
                  window.doubleValue > 0 else { continue }
            let percent = min(100, max(0, used.doubleValue * 100 / window.doubleValue))
            codexContextCache[rolloutPath] = (modified, fileSize, percent)
            return percent
        }
        return 0
    }

    func codexWorkActivity(rolloutPath: String,
                                   turnState: String) -> WorkActivitySignal {
        guard !rolloutPath.isEmpty else { return .idle }
        let attributes = try? FileManager.default.attributesOfItem(atPath: rolloutPath)
        let modified = attributes?[.modificationDate] as? Date ?? .distantPast
        let fileSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        if let cached = codexActivityCache[rolloutPath],
           cached.modified == modified, cached.size == fileSize {
            return cached.signal
        }
        let signal = BuildTestAwareness.codexRollout(path: rolloutPath, turnState: turnState)
        codexActivityCache[rolloutPath] = (modified, fileSize, signal)
        return signal
    }

    func loadCodexSessions(now: Double) -> [WorkSession] {
        let turnStates = latestCodexTurnStates()
        guard !turnStates.isEmpty else { return [] }

        var db: OpaquePointer?
        guard sqlite3_open_v2(CODEX_STATE_DB, &db,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)

        var schemaStatement: OpaquePointer?
        var hasRolloutPath = false
        if sqlite3_prepare_v2(db, "PRAGMA table_info(threads)", -1,
                              &schemaStatement, nil) == SQLITE_OK,
           let schemaStatement {
            while sqlite3_step(schemaStatement) == SQLITE_ROW {
                if sqliteText(schemaStatement, 1) == "rollout_path" {
                    hasRolloutPath = true
                    break
                }
            }
            sqlite3_finalize(schemaStatement)
        }
        let rolloutColumn = hasRolloutPath ? "rollout_path" : "''"
        let sql = """
            SELECT id, COALESCE(NULLIF(name, ''), NULLIF(title, ''), 'งาน Codex'),
                   cwd, updated_at, \(rolloutColumn), preview
            FROM threads
            WHERE archived = 0 AND preview <> '' AND thread_source = 'user'
              AND updated_at >= ?
            ORDER BY updated_at DESC
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(now - SESSION_STALE))

        var sessions: [WorkSession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqliteText(statement, 0)
            guard let rawState = turnStates[id] else { continue }
            let state: String
            switch rawState {
            case "inProgress": state = "working"
            case "completed": state = "done"
            case "failed": state = "failed"
            case "interrupted": state = "interrupted"
            default: continue
            }
            let rawTitle = sqliteText(statement, 1)
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let topic = rawTitle.count > 70 ? String(rawTitle.prefix(68)) + "…" : rawTitle
            let cwd = sqliteText(statement, 2)
            let project = cwd.isEmpty ? "Codex"
                : URL(fileURLWithPath: cwd).lastPathComponent
            let updatedAt = Double(sqlite3_column_int64(statement, 3))
            let rolloutPath = sqliteText(statement, 4)
            let contextPercent = codexContextPercent(rolloutPath: rolloutPath)
            let activity = codexWorkActivity(rolloutPath: rolloutPath, turnState: rawState)
            let preview = sqliteText(statement, 5)
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            sessions.append(WorkSession(source: "codex", id: id, state: state,
                                        name: project, cwd: cwd, message: String(preview.prefix(800)),
                                        updatedAt: updatedAt, contextPercent: contextPercent,
                                        focusURL: "codex://threads/\(id)", appPIDs: [],
                                        sessionID: "", topic: topic, activity: activity))
        }
        return sessions
    }

    /// รวมสถานะจาก Codex และ Claude Code ในกล่องเดียว แต่แยก section ตอนแสดงผล
    func pollSessions(_ dt: Double) {
        sessPoll -= dt
        guard sessPoll <= 0 else { return }
        sessPoll = 0.5
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: SESSIONS)) ?? []
        let now = Date().timeIntervalSince1970
        var waiting: [String] = []
        var working = 0
        var sessions = [WorkSession]()
        for n in names where !n.hasPrefix(".") && !n.contains(".tmp") {
            guard let d = fm.contents(atPath: SESSIONS + "/" + n),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let at = j["at"] as? Double, now - at < SESSION_STALE,
                  let st = j["state"] as? String else { continue }
            let cwd = (j["cwd"] as? String) ?? ""
            let dir = (j["dir"] as? String) ?? ""
            let name = !dir.isEmpty ? dir
                : (!cwd.isEmpty ? URL(fileURLWithPath: cwd).lastPathComponent : "งานหนึ่ง")
            let message = (j["msg"] as? String) ?? ""
            let activity = BuildTestAwareness.classify(
                state: st, message: message,
                fingerprint: "claude:\(n):\(Int(at * 1000))"
            )
            let normalizedState: String
            switch activity.kind {
            case .coding, .build, .testing: normalizedState = "working"
            case .testPassed: normalizedState = "done"
            case .testFailed: normalizedState = "failed"
            case .permission: normalizedState = "input"
            case .idle: normalizedState = st
            }
            let pct = (j["ctx_pct"] as? Double) ?? 0
            let focus = (j["focus_url"] as? String) ?? ""
            let apids = (j["app_pids"] as? [Int]) ?? []
            // ไฟล์รุ่นเก่ายังไม่มี session_id แต่ชื่อไฟล์ก็คือ UUID เดียวกัน
            let sid = (j["session_id"] as? String) ?? n
            let topic = (j["topic"] as? String) ?? ""
            let pid = (j["pid"] as? Int) ?? 0
            // ห้องที่โปรเซสตายไปแล้วแต่ไฟล์ยังค้าง ไม่ควรถูกนับหรือเอามาเตือน context
            if pid > 0, kill(pid_t(pid), 0) != 0, errno == ESRCH { continue }
            sessions.append(WorkSession(source: "claude", id: n, state: normalizedState, name: name, cwd: cwd,
                                        message: message, updatedAt: at,
                                        contextPercent: pct,
                                        focusURL: focus.hasPrefix("warp://") ? focus : "",
                                        appPIDs: apids, sessionID: sid, topic: topic,
                                        activity: activity, pid: pid,
                                        startedAt: (j["started"] as? Double) ?? at,
                                        recentFiles: ((j["files"] as? [String]) ?? []).prefix(8).map { $0 },
                                        lastRequest: (j["last_user"] as? String) ?? ""))
            if ["input", "ask", "waiting"].contains(normalizedState) { waiting.append(name) }
            else if ["working", "busy"].contains(normalizedState) { working += 1 }
        }
        let codexSessions = loadCodexSessions(now: now)
        sessions.append(contentsOf: codexSessions)
        working += codexSessions.filter { ["working", "busy"].contains($0.state) }.count
        sessions.sort {
            let left = workStateRank($0.state), right = workStateRank($1.state)
            return left == right ? $0.updatedAt > $1.updatedAt : left < right
        }
        captureReturnRitual(sessions, now: now)
        detectWorkNotices(sessions)
        updateBuildTestAwareness(sessions)
        remindLongWaitingWork(sessions, now: now)
        watchLongRunningWork(sessions, now: now)
        let signature = sessions.map {
            "\($0.source)|\($0.id)|\($0.state)|\($0.name)|\($0.cwd)|\($0.message)|\(Int($0.contextPercent.rounded()))|\(Int($0.updatedAt))"
        }.joined(separator: "\n")
        if signature != workMenuSignature {
            workMenuSignature = signature
            workSessions = sessions
            recalculateWorkCounts()
            refreshWorkInboxUI()
        }
        evaluateContextPressure(sessions)
        // สรุปเป็นสตริงเดียว เปลี่ยนเมื่อไหร่ค่อยพูด จะได้ไม่พูดซ้ำทุกครึ่งวินาที
        let summary = waiting.isEmpty ? (working > 0 ? "w\(working)" : "idle")
                                      : "a" + waiting.sorted().joined(separator: ",")
        guard summary != sessSummary else { return }
        let prev = sessSummary
        sessSummary = summary
        if ProcessInfo.processInfo.environment["PIXELCAT_DEBUG"] != nil {
            FileHandle.standardError.write("SESS \(prev) -> \(summary)\n".data(using: .utf8)!)
        }
        // กล่องแจ้งเตือนราย session ถูกสร้างใน detectWorkNotices แล้ว จึงไม่พูดสรุปรวม
        // ซ้ำอีกครั้งตรงนี้ (ซึ่งเคยทำให้ไม่รู้ว่างานไหนเสร็จ)
    }

    /// ให้ regression หมุนหนึ่งเฟรมได้ โดยไม่ต้องเปิด tick ทั้งก้อน
}
