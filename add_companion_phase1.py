from pathlib import Path
p=Path('/mnt/c7f87fc8-c643-4a5a-9e37-25aa9ea51917/pixel-cat/main.swift')
s=p.read_text()
anchor='let INBOX = NSString(string: "~/.pixelcat/inbox").expandingTildeInPath\n'
insert='''\n\n// ── Phase 1: local companion context engine (no network, no token) ──\nenum CompanionMode: Int {\n    case off = 0, quietWatch = 1, companion = 2\n    var label: String {\n        switch self { case .off: return "ปิด"; case .quietWatch: return "เฝ้าเงียบ"; case .companion: return "ผู้ช่วย" }\n    }\n}\nstruct CompanionSnapshot {\n    let activeApp: String; let userIdleSeconds: Double; let workingCount: Int\n    let waitingCount: Int; let attentionCount: Int; let hottestContext: Double\n    let focusActive: Bool; let recentEvent: String\n}\nstruct CompanionDecision { let message: String; let mood: String; let cooldown: Double }\n'''
if 'enum CompanionMode' not in s: s=s.replace(anchor,anchor+insert)
anchor='    private struct DeferredClaudeEvent {\n        let event: String\n        let message: String\n    }\n'
insert='''\n    // Local observer/rule-engine state. The provider seam can be added later.\n    private var companionMode: CompanionMode = {\n        let raw = UserDefaults.standard.object(forKey: "companionMode") as? Int\n        return CompanionMode(rawValue: raw ?? CompanionMode.quietWatch.rawValue) ?? .quietWatch\n    }()\n    private var companionPoll = 2.0\n    private var companionCooldown = 0.0\n    private var companionLastApp = ""\n    private var companionRecentEvent = ""\n'''
if 'private var companionMode:' not in s: s=s.replace(anchor,anchor+insert)
anchor='        motionItem.submenu = makeMotionMenu()\n        menu.addItem(motionItem)\n'
if 'menu.addItem(makeCompanionMenuItem())' not in s: s=s.replace(anchor,anchor+'        menu.addItem(makeCompanionMenuItem())\n',1)
anchor='        motion.submenu = makeMotionMenu()\n        m.addItem(motion)\n'
if 'm.addItem(makeCompanionMenuItem())' not in s: s=s.replace(anchor,anchor+'        m.addItem(makeCompanionMenuItem())\n',1)
anchor='    /// วาดน้อง (+ ลูกโป่งถ้ามีข้อความ) ลง PNG โดยไม่ต้องพึ่งหน้าจอ\n'
methods=r'''    // MARK: Local AI companion (Phase 1)

    private func makeCompanionMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "AI companion • \(companionMode.label)", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "AI companion")
        for mode in [CompanionMode.off, .quietWatch, .companion] {
            let title = mode == .off ? "ปิด AI companion" : "\(mode.label) — \(mode == .quietWatch ? "รับรู้แต่พูดเฉพาะเรื่องสำคัญ" : "คุยเป็นครั้งคราว")"
            let entry = NSMenuItem(title: title, action: #selector(setCompanionMode(_:)), keyEquivalent: "")
            entry.target = self; entry.tag = mode.rawValue; entry.state = mode == companionMode ? .on : .off
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        let note = NSMenuItem(title: "ทำงาน local ยังไม่ส่งข้อมูลออก", action: nil, keyEquivalent: "")
        note.isEnabled = false; submenu.addItem(note); item.submenu = submenu
        return item
    }

    @objc private func setCompanionMode(_ sender: NSMenuItem) {
        guard let mode = CompanionMode(rawValue: sender.tag) else { return }
        companionMode = mode; UserDefaults.standard.set(mode.rawValue, forKey: "companionMode")
        companionCooldown = mode == .off ? 0 : 20
        if mode == .off { if activeWorkNotice == nil { hideBubble() } }
        else { say(mode == .quietWatch ? "น้องจะเฝ้าเงียบ ๆ นะ" : "น้องจะคอยคุยด้วยเป็นครั้งคราวนะ", for: 3.0) }
        syncCompanionMenu()
    }

    private func syncCompanionMenu() {
        guard let menu = statusItem?.menu else { return }
        for item in menu.items where item.title.hasPrefix("AI companion") {
            item.title = "AI companion • \(companionMode.label)"
            for child in item.submenu?.items ?? [] {
                if let mode = CompanionMode(rawValue: child.tag) { child.state = mode == companionMode ? .on : .off }
            }
        }
    }

    private func localCompanionSnapshot() -> CompanionSnapshot {
        let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .init(rawValue: ~0)!)
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "เดสก์ท็อป"
        let waiting = workSessions.filter { isWaiting($0.state) }.count
        let working = workSessions.filter { ["working", "busy"].contains($0.state) }.count
        let attention = workSessions.filter { needsAttention($0.state) }.count
        let hottest = workSessions.map(\.contextPercent).max() ?? 0
        if app != companionLastApp { companionLastApp = app; companionRecentEvent = "เปิดใช้ \(app)" }
        return CompanionSnapshot(activeApp: app, userIdleSeconds: idle, workingCount: working,
            waitingCount: waiting, attentionCount: attention, hottestContext: hottest,
            focusActive: focusPhase != .idle, recentEvent: companionRecentEvent)
    }

    private func companionDecision(for snapshot: CompanionSnapshot) -> CompanionDecision? {
        guard companionMode == .companion, !snapshot.focusActive, !held,
              activeWorkNotice == nil, activeContextRescue == nil,
              snapshot.userIdleSeconds >= 45 else { return nil }
        if snapshot.waitingCount > 0 { return CompanionDecision(message: "มีงานรอคำตอบอยู่ \(snapshot.waitingCount) งานนะ", mood: "concerned", cooldown: 900) }
        if snapshot.hottestContext >= 80 { return CompanionDecision(message: "เห็น context ใกล้เต็มแล้วนะ ค่อย ๆ ตรวจ handoff ได้เลย", mood: "curious", cooldown: 1200) }
        if snapshot.workingCount > 0 { return CompanionDecision(message: "น้องเห็นมีงานกำลังทำอยู่ \(snapshot.workingCount) งาน เดี๋ยวนั่งเฝ้าให้", mood: "quiet", cooldown: 1200) }
        return nil
    }

    private func runLocalCompanion(_ dt: Double) {
        guard companionMode != .off else { return }
        companionPoll -= dt; companionCooldown = max(0, companionCooldown - dt)
        guard companionPoll <= 0 else { return }; companionPoll = 5.0
        let snapshot = localCompanionSnapshot()
        guard companionCooldown <= 0, let decision = companionDecision(for: snapshot) else { return }
        companionCooldown = decision.cooldown
        if ProcessInfo.processInfo.environment["PIXELCAT_DEBUG"] != nil {
            FileHandle.standardError.write("COMPANION local mood=\(decision.mood) msg=\(decision.message)\n".data(using: .utf8)!)
        }
        if decision.mood == "concerned" { setState("tilt", duration: 0.8) { [weak self] in self?.setState("sit", duration: 2.0) } }
        else if decision.mood == "curious" { setState("tilt", duration: 0.9) }
        say(decision.message, for: 4.5)
    }

'''
if 'MARK: Local AI companion' not in s: s=s.replace(anchor,methods+anchor)
anchor='    private func tick(_ dt: Double) {\n        pollSessions(dt)\n'
if 'runLocalCompanion(dt)' not in s: s=s.replace(anchor,'    private func tick(_ dt: Double) {\n        pollSessions(dt)\n        runLocalCompanion(dt)\n',1)
p.write_text(s)
rp=Path('/mnt/c7f87fc8-c643-4a5a-9e37-25aa9ea51917/pixel-cat/README.md')
r=rp.read_text(); line='- **AI companion ระยะที่ 1** — โหมด local เฝ้าบริบทจากสถานะงาน, แอปที่ active และเวลา idle โดยไม่ส่งข้อมูลออกหรือใช้ token; เลือก ปิด/เฝ้าเงียบ/ผู้ช่วย ได้จากเมนู\n'
if line not in r: r=r.replace('- **กล่องงานอัจฉริยะ + แจ้งเตือนคลิกได้**',line+'- **กล่องงานอัจฉริยะ + แจ้งเตือนคลิกได้**',1)
rp.write_text(r)
print('patched', 'enum CompanionMode' in s, 'runLocalCompanion(dt)' in s)
