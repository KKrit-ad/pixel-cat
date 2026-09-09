// PetController+ContextRescue
// Context Rescue — แพ็ก handoff ก่อน context เต็ม
//
// แยกออกมาจาก PetController.swift เป็น extension ของคลาสเดิม

import Cocoa

extension PetController {

    // MARK: Context Rescue

    /// สรุปข้อมูลที่แอปรู้จริงเท่านั้น แล้วให้ task ใหม่ตรวจ working tree ต่อเอง
    /// จึงไม่แต่งสถานะงานหรืออ้างว่ามีรายละเอียดที่ไม่ได้อ่านจาก session
    /// รันคำสั่งอ่านอย่างเดียวในโฟลเดอร์งาน คืนบรรทัดที่อ่านได้ ไม่ค้างถ้าคำสั่งเงียบ
    func readOnlyShell(_ launch: String, _ args: [String], in cwd: String,
                               limit: Int = 4000) -> String {
        guard !cwd.isEmpty,
              FileManager.default.fileExists(atPath: cwd) else { return "" }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launch)
        task.arguments = args
        task.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return "" }
        return String(text.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// หนึ่งประโยคว่าโปรเจกต์นี้คืออะไร หยิบจากเอกสารในโฟลเดอร์ ไม่ต้องให้ห้องใหม่เดา
    func projectSummary(cwd: String) -> String {
        for doc in ["CLAUDE.md", "README.md"] {
            let path = cwd + "/" + doc
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "#*_> "))
                guard line.count >= 12, !line.hasPrefix("!"), !line.hasPrefix("[") else { continue }
                return String(line.prefix(200))
            }
        }
        return ""
    }

    /// สภาพโค้ดตอนนี้จริง ๆ — ห้องใหม่จะได้เห็นว่าอะไรถูกคอมมิตไปแล้ว ไม่ทำซ้ำ
    func repositoryBriefing(cwd: String) -> [String] {
        guard !readOnlyShell("/usr/bin/git", ["rev-parse", "--is-inside-work-tree"],
                             in: cwd, limit: 20).isEmpty else { return [] }
        var lines: [String] = []
        let branch = readOnlyShell("/usr/bin/git", ["rev-parse", "--abbrev-ref", "HEAD"],
                                   in: cwd, limit: 120)
        if !branch.isEmpty { lines.append("branch: \(branch)") }
        let log = readOnlyShell("/usr/bin/git", ["log", "-5", "--pretty=format:%h %ad %s",
                                                "--date=format:%m-%d %H:%M"], in: cwd, limit: 1200)
        if !log.isEmpty {
            lines.append("คอมมิตล่าสุด (งานที่ทำเสร็จไปแล้ว ห้ามทำซ้ำ):")
            lines.append(contentsOf: log.split(separator: "\n").map { "  - " + $0 })
        }
        let status = readOnlyShell("/usr/bin/git", ["status", "--porcelain"], in: cwd, limit: 4000)
        if status.isEmpty {
            lines.append("working tree: สะอาด ไม่มีงานค้างกลางคัน")
        } else {
            let changed = status.split(separator: "\n")
            lines.append("working tree: มี \(changed.count) ไฟล์ที่ยังไม่คอมมิต")
            lines.append(contentsOf: changed.prefix(10).map { "  - " + $0.trimmingCharacters(in: .whitespaces) })
        }
        return lines
    }

    func contextHandoff(for session: WorkSession) -> String {
        let source = workSourceName(session)
        let topic = sessionHeadline(session)
        let latest = session.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceLink: String
        if !session.focusURL.isEmpty {
            sourceLink = session.focusURL
        } else if session.source == "claude",
                  let link = claudeSessionURL(resumeID(session.sessionID)) {
            sourceLink = link.absoluteString
        } else {
            sourceLink = "(ไม่มี deep link ของ task ต้นทาง)"
        }
        var lines = [
            "ทำงานนี้ต่อจาก Context Rescue ของ PixelCat",
            "",
            "แหล่งที่มา: \(source)",
            "โปรเจกต์: \(session.name)",
            "หัวข้องาน: \(topic)",
            "สถานะล่าสุด: \(session.state)",
            "context ล่าสุด: \(Int(session.contextPercent.rounded()))%",
            "โฟลเดอร์งาน: \(session.cwd.isEmpty ? "(ไม่ทราบ)" : session.cwd)",
            "task ต้นทาง: \(sourceLink)"
        ]
        if !latest.isEmpty {
            lines.append("ข้อความสถานะล่าสุด: " + String(latest.prefix(800)))
        }

        let summary = projectSummary(cwd: session.cwd)
        if !summary.isEmpty {
            lines.append(contentsOf: ["", "โปรเจกต์นี้คืออะไร: " + summary])
        }
        let request = session.lastRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !request.isEmpty {
            lines.append(contentsOf: ["", "คำสั่งล่าสุดของผู้ใช้ในห้องเก่า:",
                                      String(request.prefix(400))])
        }
        if !session.recentFiles.isEmpty {
            let shown = session.recentFiles.map { path -> String in
                guard !session.cwd.isEmpty, path.hasPrefix(session.cwd + "/") else { return path }
                return String(path.dropFirst(session.cwd.count + 1))
            }
            lines.append(contentsOf: ["", "ไฟล์ที่ห้องเก่าแก้ล่าสุด:"]
                         + shown.map { "  - " + $0 })
        }
        let repo = repositoryBriefing(cwd: session.cwd)
        if !repo.isEmpty {
            lines.append(contentsOf: [""] + repo)
        }

        lines.append(contentsOf: [
            "",
            "เริ่มงานแบบนี้:",
            "1. อ่าน git log และ working tree ข้างบน แล้วเปิดไฟล์ที่เกี่ยวข้องเพื่อดูว่าหัวข้องานนี้ทำเสร็จไปแล้วหรือยัง",
            "2. ถ้าเสร็จแล้ว อย่าทำซ้ำ — บอกผู้ใช้สั้น ๆ ว่าเสร็จแล้วที่คอมมิตไหน แล้วถามว่าจะให้ทำอะไรต่อ",
            "3. ถ้ายังไม่เสร็จ สรุปสิ่งที่เหลือก่อน แล้วทำต่อโดยไม่ย้อนงานที่เสร็จไปแล้ว",
            "หากข้อมูลไม่พอให้ถามผู้ใช้สั้น ๆ หนึ่งคำถาม"
        ])
        return lines.joined(separator: "\n")
    }

    /// Adapter ของ deep link สองแอปอยู่หลัง interface เดียว: session เข้า, rescue ออก
    func makeContextRescue(for session: WorkSession) -> ContextRescue? {
        let handoff = contextHandoff(for: session)
        var components = URLComponents()
        if session.source == "codex" {
            components.scheme = "codex"
            components.host = "new"
            components.queryItems = [URLQueryItem(name: "prompt", value: handoff)]
            if !session.cwd.isEmpty {
                components.queryItems?.append(URLQueryItem(name: "path", value: session.cwd))
            }
        } else {
            components.scheme = "claude"
            components.host = "code"
            components.path = "/new"
            components.queryItems = [URLQueryItem(name: "prompt", value: handoff)]
            if !session.cwd.isEmpty {
                components.queryItems?.append(URLQueryItem(name: "folder", value: session.cwd))
            }
        }
        guard let launchURL = components.url else { return nil }
        return ContextRescue(session: session, handoff: handoff, launchURL: launchURL)
    }

    func offerContextRescue(for session: WorkSession) {
        let key = noticeKey(session)
        guard session.contextPercent >= 90,
              !contextRescueOffered.contains(key),
              focusPhase == .idle, !held, !airborne, !climbing,
              activeWorkNotice == nil, activeContextRescue == nil,
              speechOn, let rescue = makeContextRescue(for: session) else { return }
        contextRescueOffered.insert(key)
        rememberRescue(rescue)
        activeContextRescue = rescue
        shepherdTarget = nil
        let waitReady: () -> Void = { [weak self] in
            guard let self, self.activeContextRescue != nil else { return }
            self.setState("rescueReady", duration: 12.0) { [weak self] in
                self?.activeContextRescue = nil
                self?.pickIdle()
            }
        }
        if reduceMotionEnabled { waitReady() }
        else { setState("rescuePack", duration: 1.4, then: waitReady) }
        say("context \(Int(session.contextPercent.rounded()))% • คาบ handoff พร้อมแล้ว คลิกเพื่อเปิดงานใหม่",
            for: 12.0, target: session)
    }

    /// เก็บ handoff ที่เพิ่งเสนอ ให้กดย้อนหลังได้แม้กรอบคำพูดหายไปแล้ว
    func rememberRescue(_ rescue: ContextRescue) {
        let title = "\(workSourceName(rescue.session)) • \(companionProjectName(rescue.session))"
            + " • context \(Int(rescue.session.contextPercent.rounded()))%"
        let entry = SavedRescue(title: title, urlString: rescue.launchURL.absoluteString,
                                handoff: rescue.handoff, savedAt: Date())
        // งานเดิมที่เสนอซ้ำ ให้ทับอันเก่า ไม่ให้เมนูรก
        rescueHistory.removeAll { $0.title == title }
        rescueHistory.insert(entry, at: 0)
        if rescueHistory.count > Self.rescueHistoryLimit {
            rescueHistory = Array(rescueHistory.prefix(Self.rescueHistoryLimit))
        }
        persistRescueHistory()
    }

    func persistRescueHistory() {
        UserDefaults.standard.set(rescueHistory.map(\.dictionary), forKey: Self.rescueHistoryKey)
        rescueHistoryItem?.submenu = makeRescueHistoryMenu().submenu
    }

    func makeRescueHistoryMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Handoff ที่เคยเสนอ", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Handoff ที่เคยเสนอ")
        if rescueHistory.isEmpty {
            let empty = NSMenuItem(title: "ยังไม่มี handoff ที่เคยเสนอ", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for (index, saved) in rescueHistory.enumerated() {
                let entry = NSMenuItem(title: "\(saved.title) — \(saved.ageText)",
                                       action: #selector(openSavedRescue(_:)), keyEquivalent: "")
                entry.target = self
                entry.tag = index
                submenu.addItem(entry)
            }
            submenu.addItem(.separator())
            let clear = NSMenuItem(title: "ล้างประวัติ handoff", action: #selector(clearRescueHistory),
                                   keyEquivalent: "")
            clear.target = self
            submenu.addItem(clear)
        }
        item.submenu = submenu
        return item
    }

    @objc func openSavedRescue(_ sender: NSMenuItem) {
        guard rescueHistory.indices.contains(sender.tag) else { return }
        let saved = rescueHistory[sender.tag]
        guard let url = URL(string: saved.urlString) else {
            say("ลิงก์ handoff อันนี้เสียแล้ว เปิดให้ไม่ได้นะกริช", for: 4.0); return
        }
        if ProcessInfo.processInfo.environment["PIXELCAT_SIMCONTEXTRESCUE"] != nil {
            lastSimulatedNewTaskURL = saved.urlString
            lastSimulatedHandoff = saved.handoff
        } else {
            if !saved.handoff.isEmpty {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(saved.handoff, forType: .string)
            }
            NSWorkspace.shared.open(url)
        }
        say("เปิด handoff ของ \(saved.title) ให้แล้วนะ", for: 4.0)
    }

    @objc func clearRescueHistory() {
        rescueHistory.removeAll()
        persistRescueHistory()
        say("ล้างประวัติ handoff แล้วนะ", for: 3.0)
    }

    /// ประเมินทุก session แต่เสนอ rescue เพียงครั้งเดียวจนกว่า context จะลดต่ำกว่า 70%
    /// ห้องที่พ่อเปิดห้องใหม่ในโฟลเดอร์เดียวกันไปแล้ว ถือว่าย้ายไปทำต่อที่นั่นแล้ว
    /// ไม่ต้องเตือน context หรือคาบ handoff มาให้อีก
    func supersededSessions(_ sessions: [WorkSession]) -> Set<String> {
        var superseded = Set<String>()
        for session in sessions where !session.cwd.isEmpty {
            let hasNewerRoom = sessions.contains {
                $0.cwd == session.cwd && noticeKey($0) != noticeKey(session)
                    && $0.startedAt > session.startedAt
            }
            if hasNewerRoom { superseded.insert(noticeKey(session)) }
        }
        return superseded
    }

    func evaluateContextPressure(_ allSessions: [WorkSession]) {
        let superseded = supersededSessions(allSessions)
        let sessions = allSessions.filter { !superseded.contains(noticeKey($0)) }
        let liveKeys = Set(sessions.filter { $0.contextPercent >= 70 }.map(noticeKey))
        contextRescueOffered.formIntersection(liveKeys)
        guard let hottest = sessions.filter({ $0.contextPercent > 0 })
            .max(by: { $0.contextPercent < $1.contextPercent }) else {
            ctxWarned = 0
            return
        }
        let step = hottest.contextPercent >= 90 ? 90.0
            : (hottest.contextPercent >= 80 ? 80.0 : 0)
        if step > ctxWarned {
            ctxWarned = step
            if step == 80, focusPhase == .idle, !held {
                setState("sit", duration: 5) { [weak self] in self?.pickIdle() }
                say("context ใช้ไป \(Int(hottest.contextPercent.rounded()))% แล้วนะ", for: 5)
            }
        } else if hottest.contextPercent < 70 {
            ctxWarned = 0
        }
        if let candidate = sessions
            .filter({ $0.contextPercent >= 90 && !contextRescueOffered.contains(noticeKey($0)) })
            .max(by: { $0.contextPercent < $1.contextPercent }) {
            offerContextRescue(for: candidate)
        }
    }

    @discardableResult
    func openContextRescueIfPresent() -> Bool {
        guard let rescue = activeContextRescue else { return false }
        activeContextRescue = nil
        bubbleTarget = nil
        bubbleView.interactive = false
        bubbleWindow.ignoresMouseEvents = true
        let simulated = ProcessInfo.processInfo.environment["PIXELCAT_SIMCONTEXTRESCUE"] != nil
        if simulated {
            lastSimulatedNewTaskURL = rescue.launchURL.absoluteString
            lastSimulatedHandoff = rescue.handoff
        } else {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(rescue.handoff, forType: .string)
            if !NSWorkspace.shared.open(rescue.launchURL) {
                openTarget(rescue.session)
            }
        }
        speakFor = 0
        hideBubble()
        transitionState(to: "sit", duration: 1.5)
        return true
    }
}
