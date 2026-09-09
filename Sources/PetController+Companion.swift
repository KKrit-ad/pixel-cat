// PetController+Companion
// AI companion ระยะที่ 1 — เมนู สถานะ และการตัดสินใจ local
//
// แยกออกมาจาก PetController.swift เป็น extension ของคลาสเดิม

import Cocoa

extension PetController {

    // MARK: Local AI companion (Phase 1)

    func makeCompanionMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: companionMenuTitle(), action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "AI companion")
        for mode in [CompanionMode.off, .quietWatch, .companion] {
            let title = mode == .off ? "ปิด AI companion" : "\(mode.label) — \(mode == .quietWatch ? "รับรู้แต่พูดเฉพาะเรื่องสำคัญ" : "คุยเป็นครั้งคราว")"
            let entry = NSMenuItem(title: title, action: #selector(setCompanionMode(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = mode.rawValue
            entry.state = mode == companionMode ? .on : .off
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        submenu.addItem(.separator())
        let brainHeader = NSMenuItem(title: "สมองที่ใช้ตอบ", action: nil, keyEquivalent: "")
        brainHeader.isEnabled = false
        submenu.addItem(brainHeader)
        for brain in CompanionBrain.allCases {
            let entry = NSMenuItem(title: "\(brain.label) — \(brain.detail)",
                                   action: #selector(setCompanionBrain(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = brain.rawValue
            entry.state = brain == companionBrain ? .on : .off
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        let chat = NSMenuItem(title: "คุยกับอั่งเปา…", action: #selector(activateCompanionChatShortcut),
                              keyEquivalent: "c")
        chat.target = self
        chat.keyEquivalentModifierMask = [.control, .option]
        submenu.addItem(chat)
        let reset = NSMenuItem(title: "ให้น้องลืมบทสนทนาที่ผ่านมา", action: #selector(resetCompanionChatTask), keyEquivalent: "")
        reset.target = self
        submenu.addItem(reset)
        let note = NSMenuItem(title: "ทำงาน local ยังไม่ส่งข้อมูลออก", action: nil, keyEquivalent: "")
        note.isEnabled = false
        submenu.addItem(note)
        item.submenu = submenu
        return item
    }

    func makeFileSearchMenuItem() -> NSMenuItem {
        let count = fileSearchResults.count
        let title = count == 0 ? "ของที่น้องหาเจอ" : "ของที่น้องหาเจอ • \(count)"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "ผลค้นหาในเครื่อง")
        if fileSearchResults.isEmpty {
            let empty = NSMenuItem(title: "พิมพ์ /หา ชื่อไฟล์ ในกล่องคุย", action: nil,
                                   keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for url in fileSearchResults {
                let parent = fileFinder.displayLocation(for: url)
                let entry = NSMenuItem(
                    title: "\(url.lastPathComponent) — \(parent)",
                    action: #selector(openFoundFile(_:)), keyEquivalent: ""
                )
                entry.target = self
                entry.representedObject = url.path
                menu.addItem(entry)
            }
        }
        item.submenu = menu
        return item
    }

    func makeDeliveryMenuItem() -> NSMenuItem {
        let suffix = deliveryEnabled ? "เปิด" : "ปิด"
        let item = NSMenuItem(title: "Delivery Cat • \(suffix)", action: nil,
                              keyEquivalent: "")
        let menu = NSMenu(title: "Delivery Cat")
        let toggle = NSMenuItem(title: deliveryEnabled ? "หยุดเฝ้าไฟล์ใหม่" : "เริ่มเฝ้าไฟล์ใหม่",
                                action: #selector(toggleDeliveryCat), keyEquivalent: "")
        toggle.target = self
        toggle.state = deliveryEnabled ? .on : .off
        menu.addItem(toggle)
        menu.addItem(.separator())
        if deliveryHistory.isEmpty {
            let empty = NSMenuItem(title: "ยังไม่มีพัสดุใหม่ในรอบนี้", action: nil,
                                   keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for batch in deliveryHistory.prefix(10) {
                let entry = NSMenuItem(title: batch.title,
                                       action: #selector(openDeliveryHistory(_:)),
                                       keyEquivalent: "")
                entry.target = self
                entry.representedObject = batch.items.map { $0.url.path }
                entry.isEnabled = batch.items.contains {
                    FileManager.default.fileExists(atPath: $0.url.path)
                }
                menu.addItem(entry)
            }
        }
        let note = NSMenuItem(title: "เฝ้า Downloads, AirDrop และ Screenshot แบบ local",
                              action: nil, keyEquivalent: "")
        note.isEnabled = false
        menu.addItem(.separator())
        menu.addItem(note)
        item.submenu = menu
        return item
    }

    func refreshDeliveryMenu() {
        guard let item = deliveryMenuItem else { return }
        let replacement = makeDeliveryMenuItem()
        item.title = replacement.title
        item.submenu = replacement.submenu
    }

    @objc func toggleDeliveryCat() {
        deliveryEnabled.toggle()
        UserDefaults.standard.set(deliveryEnabled, forKey: "deliveryEnabled")
        if deliveryEnabled {
            deliveryWatcher.seed()
            say("น้องจะเฝ้าพัสดุใหม่ให้นะ", for: 3.0)
        } else {
            collectingDeliveries.removeAll()
            deliveryQueue.removeAll()
            if activeDelivery != nil {
                activeDelivery = nil
                speakFor = 0
                hideBubble()
            }
            say("พักงานส่งพัสดุก่อนนะ", for: 3.0)
        }
        refreshDeliveryMenu()
    }

    @objc func openDeliveryHistory(_ sender: NSMenuItem) {
        guard let paths = sender.representedObject as? [String] else { return }
        let urls = paths.map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func refreshFileSearchMenu() {
        guard let item = fileSearchMenuItem else { return }
        let replacement = makeFileSearchMenuItem()
        item.title = replacement.title
        item.submenu = replacement.submenu
    }

    @objc func openFoundFile(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        revealFoundFile(URL(fileURLWithPath: path))
    }

    @objc func setCompanionMode(_ sender: NSMenuItem) {
        guard let mode = CompanionMode(rawValue: sender.tag) else { return }
        companionMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "companionMode")
        companionCooldown = mode == .off ? 0 : 20
        if mode == .companion && activeCompanion != nil && !companionRequestInFlight {
            setCompanionConnectionStatus("พร้อมใช้งาน • ยังไม่ได้เรียก")
        }
        if mode == .off {
            if activeWorkNotice == nil { hideBubble() }
        } else {
            say(mode == .quietWatch ? "น้องจะเฝ้าเงียบ ๆ นะ" : "น้องจะคอยคุยด้วยเป็นครั้งคราวนะ", for: 3.0)
        }
        syncCompanionMenu()
    }

    func syncCompanionMenu() {
        guard let menu = statusItem?.menu else { return }
        for item in menu.items where item.title.hasPrefix("AI companion") {
            item.title = companionMenuTitle()
            for child in item.submenu?.items ?? [] {
                if child.action == #selector(setCompanionBrain(_:)) {
                    if let brain = CompanionBrain(rawValue: child.tag) { child.state = brain == companionBrain ? .on : .off }
                } else if child.action == #selector(setCompanionMode(_:)),
                          let mode = CompanionMode(rawValue: child.tag) {
                    child.state = mode == companionMode ? .on : .off
                }
            }
        }
    }

    func companionMenuTitle() -> String {
        "AI companion • \(companionMode.label) • \(companionBrain.label): \(companionConnectionStatus)"
    }

    func setCompanionConnectionStatus(_ status: String) {
        guard companionConnectionStatus != status else { return }
        companionConnectionStatus = status
        syncCompanionMenu()
        if ProcessInfo.processInfo.environment["PIXELCAT_DEBUG"] != nil {
            FileHandle.standardError.write("COMPANION STATUS \(status)\n".data(using: .utf8)!)
        }
    }

    func localCompanionSnapshot() -> CompanionSnapshot {
        let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .init(rawValue: ~0)!)
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "เดสก์ท็อป"
        let waiting = workSessions.filter { isWaiting($0.state) }.count
        let working = workSessions.filter { ["working", "busy"].contains($0.state) }.count
        let attention = workSessions.filter { needsAttention($0.state) }.count
        let hottest = workSessions.map(\.contextPercent).max() ?? 0
        if app != companionLastApp {
            companionLastApp = app
            companionRecentEvent = "เปิดใช้ \(app)"
        }
        return CompanionSnapshot(activeApp: app, userIdleSeconds: idle, workingCount: working,
                                 waitingCount: waiting, attentionCount: attention,
                                 hottestContext: hottest, focusActive: focusPhase != .idle,
                                 recentEvent: companionRecentEvent,
                                 workBriefs: companionWorkBriefs())
    }

    /// ชื่อโปรเจกต์สำหรับส่งออกนอกเครื่อง — เอาเฉพาะโฟลเดอร์ท้ายสุด ไม่ให้ path เต็มหลุดไปหา AI
    func companionProjectName(_ session: WorkSession) -> String {
        let raw = session.name.isEmpty ? session.cwd : session.name
        let leaf = raw.hasPrefix("/") ? (raw as NSString).lastPathComponent : raw
        let cleaned = leaf.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "ไม่ทราบชื่อ" : noticeProjectName(cleaned)
    }

    /// ใช้เฉพาะใน BRAINTEST — ยิงรอบสองเพื่อดูว่าน้องจำรอบแรกได้ไหม
    func provider2(_ provider: CompanionProvider, message: String,
                               snapshot: CompanionSnapshot, done: @escaping (String) -> Void) {
        provider.chat(message: message, memory: companionMemory, snapshot: snapshot) { outcome in
            switch outcome {
            case .reply(let text): done(text)
            case .failure(let reason): done("FAIL: \(reason)")
            }
        }
    }

    /// สรุปงานจริงให้ AI อ่าน — ส่งแค่ชื่อโฟลเดอร์ท้ายสุด ไม่ส่ง path เต็ม ไม่ส่งเนื้อแชทหรือโค้ด
    func companionWorkBriefs(limit: Int = 6) -> [String] {
        workSessions
            .sorted { workStateRank($0.state) > workStateRank($1.state) }
            .prefix(limit)
            .map { session in
                var parts = [workSourceName(session),
                             companionProjectName(session),
                             workStateLabel(session)]
                if session.contextPercent > 0 {
                    parts.append("context \(Int(session.contextPercent.rounded()))%")
                }
                let topic = session.topic.trimmingCharacters(in: .whitespacesAndNewlines)
                if !topic.isEmpty { parts.append("หัวข้อ: \(topic)") }
                return parts.joined(separator: " • ")
            }
    }

    /// บอกให้ตรงว่าสมองที่เลือกใช้ไม่ได้เพราะอะไร ไม่ใช่ "ไม่ได้ตั้ง API key" ลอย ๆ
    var brainUnavailableText: String {
        switch companionBrain {
        case .localOnly: return "Local เท่านั้น • ไม่ส่งข้อมูลออก"
        case .claude: return "ไม่พบ claude CLI และไม่มี ANTHROPIC_API_KEY • ใช้ local"
        case .manus: return "ไม่ได้ตั้ง PIXELCAT_MANUS_API_KEY • ใช้ local"
        }
    }

    @objc func setCompanionBrain(_ sender: NSMenuItem) {
        guard let brain = CompanionBrain(rawValue: sender.tag) else { return }
        companionBrain = brain
        UserDefaults.standard.set(brain.rawValue, forKey: "companionBrain")
        setCompanionConnectionStatus(activeCompanion.map { "\($0.brandName) • พร้อมใช้งาน" } ?? brainUnavailableText)
        say("เปลี่ยนสมองเป็น \(brain.label) แล้วนะ", for: 3.5)
        syncCompanionMenu()
    }

    func companionDecision(for snapshot: CompanionSnapshot) -> CompanionDecision? {
        guard companionMode == .companion, !snapshot.focusActive, !held,
              activeWorkNotice == nil, activeContextRescue == nil,
              snapshot.userIdleSeconds >= 45 else { return nil }
        if snapshot.waitingCount > 0 {
            return CompanionDecision(message: "มีงานรอคำตอบอยู่ \(snapshot.waitingCount) งานนะ", mood: "concerned", cooldown: 900)
        }
        if snapshot.hottestContext >= 80 {
            return CompanionDecision(message: "เห็น context ใกล้เต็มแล้วนะ ค่อย ๆ ตรวจ handoff ได้เลย", mood: "curious", cooldown: 1200)
        }
        if snapshot.workingCount > 0 {
            return CompanionDecision(message: "น้องเห็นมีงานกำลังทำอยู่ \(snapshot.workingCount) งาน เดี๋ยวนั่งเฝ้าให้", mood: "quiet", cooldown: 1200)
        }
        return nil
    }

    func runLocalCompanion(_ dt: Double) {
        guard companionMode != .off, !chatBusy else { return }
        companionPoll -= dt
        companionCooldown = max(0, companionCooldown - dt)
        guard companionPoll <= 0 else { return }
        companionPoll = 5.0
        let snapshot = localCompanionSnapshot()
        guard companionCooldown <= 0, let fallback = companionDecision(for: snapshot) else { return }
        if let provider = activeCompanion, !companionRequestInFlight {
            companionRequestInFlight = true
            setCompanionConnectionStatus("กำลังทำงานอยู่")
            provider.decide(memory: companionMemory, snapshot: snapshot) { [weak self] decision in
                guard let self else { return }
                self.companionRequestInFlight = false
                self.setCompanionConnectionStatus(decision == nil ? "API error • ใช้ local" : "เชื่อมต่อแล้ว")
                let brand = provider.brandName
                self.applyCompanionDecision(decision ?? fallback, source: decision == nil ? "local-fallback" : brand)
            }
            return
        }
        if activeCompanion == nil { setCompanionConnectionStatus(self.brainUnavailableText) }
        applyCompanionDecision(fallback, source: "local")
    }

    func applyCompanionDecision(_ decision: CompanionDecision, source: String) {
        companionCooldown = decision.cooldown
        if ProcessInfo.processInfo.environment["PIXELCAT_DEBUG"] != nil {
            FileHandle.standardError.write("COMPANION \(source) mood=\(decision.mood) msg=\(decision.message)\n".data(using: .utf8)!)
        }
        guard !decision.message.isEmpty else { return }
        if decision.mood == "concerned" {
            setState("tilt", duration: 0.8) { [weak self] in self?.setState("sit", duration: 2.0) }
        } else if decision.mood == "curious" {
            setState("tilt", duration: 0.9)
        }
        say(decision.message, for: 4.5)
    }

    /// วาดน้อง (+ ลูกโป่งถ้ามีข้อความ) ลง PNG โดยไม่ต้องพึ่งหน้าจอ
    func snapshot(to path: String, pose: String, text: String) {
        setState(POSES[pose] != nil ? pose : "sit", duration: 99)
        applyFrame()
        func bitmap(_ v: NSView) -> NSBitmapImageRep? {
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
            v.cacheDisplay(in: v.bounds, to: rep)
            return rep
        }
        var bub: NSBitmapImageRep? = nil
        if !text.isEmpty {
            bubbleView.text = text
            let sz = BubbleView.size(for: text)
            bubbleWindow.setContentSize(sz)
            bubbleView.frame = NSRect(origin: .zero, size: sz)
            bubbleView.needsDisplay = true
            bub = bitmap(bubbleView)
        }
        guard let cat = bitmap(view) else { return }
        let gap: CGFloat = bub == nil ? 0 : 6
        let W = max(CGFloat(cat.pixelsWide), CGFloat(bub?.pixelsWide ?? 0))
        let H = CGFloat(cat.pixelsHigh) + (bub.map { CGFloat($0.pixelsHigh) + gap } ?? 0)
        let canvas = NSImage(size: NSSize(width: W, height: H))
        canvas.lockFocus()
        NSColor(calibratedRed: 0.957, green: 0.965, blue: 0.949, alpha: 1).setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: W, height: H))
        NSGraphicsContext.current?.imageInterpolation = .none
        cat.draw(in: NSRect(x: (W - CGFloat(cat.pixelsWide)) / 2, y: 0,
                            width: CGFloat(cat.pixelsWide), height: CGFloat(cat.pixelsHigh)))
        if let b = bub {
            b.draw(in: NSRect(x: (W - CGFloat(b.pixelsWide)) / 2,
                              y: CGFloat(cat.pixelsHigh) + gap,
                              width: CGFloat(b.pixelsWide), height: CGFloat(b.pixelsHigh)))
        }
        canvas.unlockFocus()
        guard let tiff = canvas.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        FileHandle.standardError.write("snapshot -> \(path)  \(Int(W))x\(Int(H))\n".data(using: .utf8)!)
    }
}
