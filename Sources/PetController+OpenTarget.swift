// PetController+OpenTarget
// เส้นทางกลับไปหางาน — deep link, sidebar, resume, โฟลเดอร์
//
// แยกออกมาจาก PetController.swift เป็น extension ของคลาสเดิม

import Cocoa

extension PetController {

    /// ทางที่จะพากลับไปหางาน เรียงตามความเจาะจง แยกออกมาเป็นค่าเดียวเพื่อตรวจได้
    enum OpenRoute: String {
        case deepLink, sessionLink, sidebarRow, resume, focusApp, folder, none
    }

    /// ลิงก์ที่พาไปห้องเดิมในแอป Claude ไม่ใช่เปิดห้องใหม่
    ///
    /// claude://resume สร้างห้องใหม่จาก transcript เดิม พอห้องนั้นยังเปิดอยู่
    /// จะได้ห้องชื่อซ้ำเพิ่มมาอีกอัน ส่วน claude://code/continue จะไปหาห้องที่มีอยู่
    /// ในรายการของแอปแล้วเปลี่ยนหน้าไปที่ห้องนั้นตรง ๆ ใช้ได้ทั้งห้องที่เปิดและปิดอยู่
    func claudeSessionURL(_ sessionID: String) -> URL? {
        guard !sessionID.isEmpty, var c = URLComponents(string: "claude://code/continue") else {
            return nil
        }
        // แอปเรียกห้องในเครื่องว่า local_<uuid> ส่ง uuid เปล่าไปจะโดนตีกลับว่า
        // "code entry link invalid ?session" แล้วเงียบ ไม่พาไปไหนเลย
        let appID = sessionID.hasPrefix("local_") ? sessionID : "local_" + sessionID
        c.queryItems = [URLQueryItem(name: "session", value: appID),
                        URLQueryItem(name: "source", value: "pixelcat")]
        return c.url
    }

    /// ลิงก์ห้องของ Claude ถูกปิดไว้ฝั่งแอปหรือเปล่า รู้ได้จาก log ที่แอปเขียนเองหลังกด
    static let claudeLogPath = NSString(string: "~/Library/Logs/Claude/main.log")
        .expandingTildeInPath

    func verifyClaudeSessionLink(from cursor: UInt64, pids: [Int], path: String,
                                         sessionID: String, topic: String, project: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            let added = ClaudeDeepLinkLog.text(at: Self.claudeLogPath, since: cursor)
            guard ClaudeDeepLinkLog.isRejected(added) else { return }
            self.claudeSessionLinkBlocked = true
            self.requestAccessibilityOnce()
            self.openTargetFallback(pids: pids, path: path, sessionID: sessionID,
                                    topic: topic, project: project)
        }
    }

    /// ขอสิทธิ์ Accessibility ครั้งเดียว เพราะการกดแถวหรือวางข้อความแทนพ่อต้องใช้สิทธิ์นี้
    func requestAccessibilityOnce() {
        guard !askedForAccessibility, !AXIsProcessTrusted() else { return }
        askedForAccessibility = true
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        say("ขอสิทธิ์ Accessibility ให้น้องหน่อยนะคะ จะได้เปิดห้องและวางคำถามให้พ่อได้",
            for: 10.0)
    }

    func openRoute(focus: String, path: String, pids: [Int],
                           sessionID: String, topic: String = "") -> OpenRoute {
        if (focus.hasPrefix("warp://") || focus.hasPrefix("codex://")), URL(string: focus) != nil {
            return .deepLink
        }
        if !claudeSessionLinkBlocked, claudeSessionURL(sessionID) != nil { return .sessionLink }
        // ลิงก์ถูกปิด แต่ยังกดแถวใน sidebar ให้ได้ ถ้ารู้ว่าเป็นห้องไหนของโปรเจกต์ไหน
        if claudeSessionLinkBlocked, !topic.isEmpty, AXIsProcessTrusted() { return .sidebarRow }
        if focusableApp(pids) != nil { return .focusApp }
        if !path.isEmpty, FileManager.default.fileExists(atPath: path) { return .folder }
        return .none
    }

    func openTarget(focus: String, path: String, pidList: String, sessionID: String,
                            topic: String = "", project: String = "") {
        let pids = pidList.split(separator: ",").compactMap { Int($0) }
        if claudeSessionLinkBlocked, !topic.isEmpty, !AXIsProcessTrusted() {
            requestAccessibilityOnce()
        }
        switch openRoute(focus: focus, path: path, pids: pids, sessionID: sessionID,
                         topic: topic) {
        case .deepLink:
            // deep link ที่เจาะจงแท็บ — Warp สำหรับ Claude Code, codex:// สำหรับ Codex
            if let u = URL(string: focus), NSWorkspace.shared.open(u) { return }
        case .sessionLink:
            // จำ offset ก่อนส่ง URL เพราะ Claude อาจตอบและเขียน log เร็วกว่าที่ open() คืนค่า
            let cursor = ClaudeDeepLinkLog.cursor(at: Self.claudeLogPath)
            if let u = claudeSessionURL(sessionID), NSWorkspace.shared.open(u) {
                // ลิงก์ห้องอาจถูกปิดไว้ฝั่งแอป แล้วเงียบไปเฉย ๆ ไม่พาไปไหน
                // ถ้าเจอว่าถูกปิด ก็ดึงแอปขึ้นหน้าให้แทน จะได้ไม่กดแล้วไม่มีอะไรเกิดขึ้น
                verifyClaudeSessionLink(from: cursor, pids: pids, path: path,
                                        sessionID: sessionID, topic: topic, project: project)
                return
            }
        case .sidebarRow, .resume, .focusApp, .folder, .none:
            break
        }
        openTargetFallback(pids: pids, path: path, sessionID: sessionID,
                           topic: topic, project: project)
    }

    /// ทางถอยเมื่อลิงก์ที่ถูกต้องใช้ไม่ได้ ไล่จากเจาะจงที่สุดลงมา
    /// กติกาเดียวคือกดแล้วต้องมีอะไรเกิดขึ้นเสมอ ไม่ปล่อยให้เงียบ
    /// ทางถอยที่จะเลือก แยกออกมาเป็นค่าเดียวเพื่อตรวจได้ว่าไม่มีช่องไหนจบลงที่ "ไม่ทำอะไร"
    func fallbackRoute(pids: [Int], path: String, sessionID: String,
                               topic: String) -> OpenRoute {
        if !topic.isEmpty, AXIsProcessTrusted() { return .sidebarRow }
        if !sessionID.isEmpty { return .resume }
        if focusableApp(pids) != nil { return .focusApp }
        if !path.isEmpty, FileManager.default.fileExists(atPath: path) { return .folder }
        return .none
    }

    func openTargetFallback(pids: [Int], path: String, sessionID: String,
                                    topic: String, project: String) {
        switch fallbackRoute(pids: pids, path: path, sessionID: sessionID, topic: topic) {
        case .sidebarRow:
            // กดแถวใน sidebar — ไปถึงห้องเดิมโดยไม่มีห้องซ้ำ ต้องได้สิทธิ์ Accessibility ก่อน
            if ClaudeSidebar.focusSession(topic: topic, project: project) { return }
        case .resume, .deepLink, .sessionLink, .focusApp, .folder, .none:
            break
        }
        // resume ไปถึงห้องนั้นได้จริงเสมอ แลกกับห้องซ้ำหนึ่งอันในรายการ
        // ยอมรับข้อเสียนี้ดีกว่ากดแล้วไม่ไปไหนเลย
        if !sessionID.isEmpty, var c = URLComponents(string: "claude://resume") {
            c.queryItems = [URLQueryItem(name: "session", value: sessionID),
                            URLQueryItem(name: "source", value: "pixelcat")]
            if let u = c.url, NSWorkspace.shared.open(u) { return }
        }
        if let app = focusableApp(pids) { app.activate(); return }
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }
}
