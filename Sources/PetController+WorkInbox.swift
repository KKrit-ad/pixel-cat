// PetController+WorkInbox
// กล่องงานรวม Codex/Claude และ Task Shepherd
//
// แยกออกมาจาก PetController.swift เป็น extension ของคลาสเดิม

import Cocoa

extension PetController {

    func item(_ title: String, _ action: Selector, tag: Int = -1) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.target = self
        mi.tag = tag
        return mi
    }

    func syncMenu() {
        statusItem.menu?.items.first(where: { $0.tag == 0 })?.state = follow ? .on : .off
        statusItem.menu?.items.first(where: { $0.tag == 1 })?.state = paused ? .on : .off
        statusItem.menu?.items.first(where: { $0.tag == 2 })?.state = onTop ? .on : .off
        statusItem.menu?.items.first(where: { $0.tag == 3 })?.state = speechOn ? .on : .off
        statusItem.menu?.items.first(where: { $0.title == "เสียงเหมียว" })?.state =
            CatVoice.shared.enabled ? .on : .off
        if let sizes = statusItem.menu?.items.first(where: { $0.title == "ขนาด" })?.submenu {
            for mi in sizes.items { mi.state = (CGFloat(mi.tag) / 10 == scale) ? .on : .off }
        }
        motionMenuItem?.title = "ความซน • \(effectiveMotionLevel.label)"
        motionMenuItem?.submenu = makeMotionMenu()
        cinemaMenuItem?.title = cinemaMenuTitle
        cinemaMenuItem?.submenu = makeCinemaMenu()
        refreshDeliveryMenu()
        updateFocusUI(force: true)
    }

    var workInboxTitle: String {
        if workAlertCount > 0 { return "กล่องงาน • ต้องดู \(workAlertCount)" }
        if workActiveCount > 0 { return "กล่องงาน • กำลังทำ \(workActiveCount)" }
        if !workSessions.isEmpty { return "กล่องงาน • ล่าสุด \(workSessions.count)" }
        return "กล่องงาน • ไม่มีงานล่าสุด"
    }

    func workStateLabel(_ session: WorkSession) -> String {
        switch session.activity.kind {
        case .coding: return "⌨️ กำลังแก้โค้ด"
        case .build: return "🛠 กำลัง build"
        case .testing: return "🧪 กำลังทดสอบ"
        case .testPassed: return "✅ test ผ่าน"
        case .testFailed: return "🔴 test พัง"
        case .permission: return "🟠 รอ permission"
        case .idle: break
        }
        switch session.state {
        case "input", "ask", "waiting": return "🟠 รอคำตอบ"
        case "working", "busy": return "🔵 กำลังทำ"
        case "fail", "failed", "error": return "🔴 พัง"
        case "interrupted": return "⚪️ หยุดแล้ว"
        case "idle", "done": return "✅ เสร็จแล้ว"
        default: return "⚪️ \(state)"
        }
    }

    func workStateRank(_ state: String) -> Int {
        switch state {
        case "input", "ask", "waiting", "fail", "failed", "error": return 0
        case "working", "busy": return 1
        case "idle", "done": return 2
        default: return 3
        }
    }

    func needsAttention(_ state: String) -> Bool {
        ["input", "ask", "waiting", "fail", "failed", "error"].contains(state)
    }

    func isWaiting(_ state: String) -> Bool {
        ["input", "ask", "waiting"].contains(state)
    }

    func recalculateWorkCounts() {
        workAlertCount = workSessions.filter {
            needsAttention($0.state) && !acknowledgedWorkKeys.contains(noticeKey($0))
        }.count
        workActiveCount = workSessions.filter {
            ["working", "busy"].contains($0.state)
        }.count
    }

    func acknowledgeWork(source: String, id: String) {
        let key = "\(source):\(id)"
        acknowledgedWorkKeys.insert(key)
        waitingReminderSent.insert(key)
        recalculateWorkCounts()
        refreshWorkInboxUI()
    }

    func sessionHeadline(_ session: WorkSession) -> String {
        session.topic.isEmpty ? session.name : session.topic
    }

    func addWorkSection(_ source: String, title: String, to menu: NSMenu) {
        let sessions = workSessions.filter { $0.source == source }
        let header = NSMenuItem(title: "\(title) • \(sessions.count)", action: nil,
                                keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        guard !sessions.isEmpty else {
            let empty = NSMenuItem(title: "    ไม่มีงานใน 15 นาทีล่าสุด", action: nil,
                                   keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        for session in sessions.prefix(INBOX_MAX) {
            let context = session.contextPercent > 0
                ? " • ctx \(Int(session.contextPercent.rounded()))%" : ""
            let title = "\(workStateLabel(session)) • \(sessionHeadline(session))"
            let entry = NSMenuItem(title: title, action: #selector(openWorkSession(_:)),
                                   keyEquivalent: "")
            entry.target = self
            let canJump = !session.focusURL.isEmpty || !resumeID(session.sessionID).isEmpty
                || focusableApp(session.appPIDs) != nil
            entry.representedObject = [session.focusURL, session.cwd,
                                       session.appPIDs.map(String.init).joined(separator: ","),
                                       resumeID(session.sessionID), session.source, session.id,
                                       session.topic, session.name]
            entry.isEnabled = canJump
                || (!session.cwd.isEmpty && FileManager.default.fileExists(atPath: session.cwd))
            if canJump { entry.title = "↩︎ " + title }
            menu.addItem(entry)

            // บรรทัดรอง: โปรเจกต์และ context แยกจากชื่อ task/session
            var sub = session.topic.isEmpty ? "" : session.name
            if !context.isEmpty { sub += sub.isEmpty ? String(context.dropFirst(3)) : context }
            if !sub.isEmpty {
                let where_ = NSMenuItem(title: "    \(sub)", action: nil, keyEquivalent: "")
                where_.isEnabled = false
                menu.addItem(where_)
            }
            if !session.message.isEmpty {
                let shortened = session.message.count > 72
                    ? String(session.message.prefix(72)) + "…" : session.message
                let detail = NSMenuItem(title: "    \(shortened)", action: nil,
                                        keyEquivalent: "")
                detail.isEnabled = false
                menu.addItem(detail)
            }
        }
        if sessions.count > INBOX_MAX {
            let more = NSMenuItem(title: "… และอีก \(sessions.count - INBOX_MAX) งาน",
                                  action: nil, keyEquivalent: "")
            more.isEnabled = false
            menu.addItem(more)
        }
    }

    func makeWorkInboxMenu() -> NSMenu {
        let menu = NSMenu()
        addWorkSection("codex", title: "Codex", to: menu)
        menu.addItem(.separator())
        addWorkSection("claude", title: "Claude Code", to: menu)
        menu.addItem(.separator())
        let hint = NSMenuItem(title: "↩︎ = พาไป session นั้น • ไม่มี = เปิดโฟลเดอร์", action: nil,
                              keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        return menu
    }

    func refreshWorkInboxUI() {
        workInboxItem?.title = workInboxTitle
        workInboxItem?.submenu = makeWorkInboxMenu()
        updateStatusTitle()
    }

    /// คลิกรายการในกล่องงาน — ถ้าเทอร์มินัลให้ URL ต่อแท็บมา ให้กระโดดไปแท็บนั้นเลย
    /// ไม่งั้นถอยไปเปิดโฟลเดอร์โปรเจกต์เหมือนเดิม (เทอร์มินัลส่วนใหญ่ยังไม่มี URL แบบนี้)
    /// แอป GUI ตัวแรกในสายโปรเซส — .app ตัวแรกที่เจออาจเป็นโปรเซสลูกที่สั่งไม่ได้
    /// (เช่น claude helper ของแอปเดสก์ท็อป) เลยต้องไล่ทั้งสายและเช็ค activationPolicy
    /// session id ที่ปลอดภัยพอจะใส่ลง URL — รับเฉพาะรูปแบบ UUID (ตัวอักษร ตัวเลข ขีด)
    func resumeID(_ raw: String) -> String {
        guard raw.count >= 8, raw.count <= 64 else { return "" }
        let ok = CharacterSet(charactersIn: "abcdefABCDEF0123456789-")
        return raw.unicodeScalars.allSatisfy(ok.contains) ? raw : ""
    }

    func focusableApp(_ pids: [Int]) -> NSRunningApplication? {
        for p in pids {
            guard let a = NSRunningApplication(processIdentifier: pid_t(p)) else { continue }
            if a.activationPolicy == .regular { return a }
        }
        // pid ที่ hook จดไว้ค้างทันทีที่แอปถูกเปิดใหม่ ถ้าหาไม่เจอก็ยังต้องมีแอปให้ดึงขึ้นมา
        return ClaudeSidebar.runningApp()
    }

    @objc func openWorkSession(_ sender: NSMenuItem) {
        guard let parts = sender.representedObject as? [String], parts.count >= 4 else { return }
        if parts.count >= 6 { acknowledgeWork(source: parts[4], id: parts[5]) }
        openTarget(focus: parts[0], path: parts[1], pidList: parts[2], sessionID: parts[3],
                   topic: parts.count >= 8 ? parts[6] : "",
                   project: parts.count >= 8 ? parts[7] : "")
    }

    func openTarget(_ session: WorkSession) {
        if ProcessInfo.processInfo.environment["PIXELCAT_SIMCOURIER"] != nil
            || ProcessInfo.processInfo.environment["PIXELCAT_SIMSHEPHERD"] != nil
            || ProcessInfo.processInfo.environment["PIXELCAT_SIMWORKNOTICE"] != nil
            || ProcessInfo.processInfo.environment["PIXELCAT_SIMRETURNRITUAL"] != nil {
            lastSimulatedOpenURL = session.focusURL.isEmpty ? session.cwd : session.focusURL
            return
        }
        openTarget(focus: session.focusURL, path: session.cwd,
                   pidList: session.appPIDs.map(String.init).joined(separator: ","),
                   sessionID: resumeID(session.sessionID),
                   topic: session.topic, project: session.name)
    }

    /// หาหน้าต่างของแอปที่เป็นเจ้าของงาน โดยอ่านเฉพาะ bounds/PID จาก Window Server
    /// แล้วแปลงพิกัดบนซ้ายของ Quartz เป็นพิกัดล่างซ้ายของ AppKit
    func taskWindowRect(_ session: WorkSession) -> CGRect? {
        if let simulatedShepherdRect { return simulatedShepherdRect }
        var pids = Set(session.appPIDs.map(Int32.init))
        if session.source == "codex" {
            for app in NSWorkspace.shared.runningApplications {
                let name = (app.localizedName ?? "").lowercased()
                let bundle = (app.bundleIdentifier ?? "").lowercased()
                if name.contains("codex") || bundle.contains("codex") {
                    pids.insert(app.processIdentifier)
                }
            }
        }
        guard !pids.isEmpty else { return nil }
        let flip = NSScreen.screens.first?.frame.maxY ?? 900
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                     kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        return list.compactMap { item -> CGRect? in
            guard (item[kCGWindowLayer as String] as? Int) == 0,
                  let pid = item[kCGWindowOwnerPID as String] as? Int32, pids.contains(pid),
                  let b = item[kCGWindowBounds as String] as? [String: CGFloat],
                  let bx = b["X"], let by = b["Y"], let bw = b["Width"], let bh = b["Height"],
                  bw > 170, bh > 100 else { return nil }
            return CGRect(x: bx, y: flip - by - bh, width: bw, height: bh)
        }.max(by: { $0.width * $0.height < $1.width * $1.height })
    }

    /// เดินไปทางหน้าต่างที่ต้องดู แล้วชี้ค้างไว้; ไม่แย่ง Focus mode
    func startTaskShepherd(_ session: WorkSession) {
        guard focusPhase == .idle, !held, !airborne, !climbing else { return }
        shepherdTarget = session
        let destination = taskWindowRect(session)
        let targetMidX = destination?.midX
            ?? (session.source == "codex" ? plat.maxX : plat.minX)
        let goRight = targetMidX >= x + spriteW / 2
        dir = goRight ? 1 : -1
        let distance = min(220, max(84, abs(targetMidX - (x + spriteW / 2))))
        target = clampX(x + dir * distance)
        hurry = false
        setState("walk", duration: 99) { [weak self] in
            guard let self, self.shepherdTarget != nil else { return }
            self.setState("point", duration: 8.0) { [weak self] in
                self?.shepherdTarget = nil
                self?.pickIdle()
            }
        }
    }

    /// CatView เรียกเมื่อคลิกตัวน้องระหว่างชี้งาน; bubble และตัวน้องเปิดปลายทางเดียวกัน
    func openShepherdTargetIfPresent() -> Bool {
        guard let session = shepherdTarget else { return false }
        shepherdTarget = nil
        acknowledgeWork(source: session.source, id: session.id)
        openTarget(session)
        return true
    }
}
