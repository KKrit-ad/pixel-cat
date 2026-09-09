// PetController+Courier
// Drag-to-Ask และ Drag Courier
//
// แยกออกมาจาก PetController.swift เป็น extension ของคลาสเดิม

import Cocoa
import Carbon

extension PetController {

    // MARK: Drag Courier

    func courierDropRegistrationChanged(_ registered: Bool) {
        courierDropRegistered = registered
    }

    func courierDragEntered() {
        guard focusPhase == .idle, !held else { return }
        setState("point", duration: 99)
        say("ฝากอะไรให้น้องคาบไปส่งได้เลย", for: 2.0)
    }

    func courierDragExited() {
        guard pendingCourierPayload == nil, focusPhase == .idle else { return }
        transitionState(to: "sit", duration: 1.0)
    }

    @discardableResult
    func receiveCourierDrop(files: [URL], text: String?) -> Bool {
        let safeFiles = files.filter(\.isFileURL)
        let safeText = safeFiles.isEmpty
            ? (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : ""
        guard !safeFiles.isEmpty || !safeText.isEmpty else { return false }
        guard workSessions.contains(where: { $0.source == "codex" || $0.source == "claude" }) else {
            say("ยังไม่มีงาน Codex หรือ Claude ให้ถาม", for: 3.5)
            return true
        }
        pendingCourierPayload = CourierPayload(files: safeFiles, text: safeText)
        if focusPhase == .idle, !held {
            setState(reduceMotionEnabled ? "sit" : "tilt", duration: 999)
        }
        openCompanionChat()
        return true
    }

    func suggestedCourierQuestion(_ payload: CourierPayload) -> String {
        if payload.files.count > 1 {
            return "ช่วยดูไฟล์เหล่านี้และสรุปสิ่งสำคัญให้หน่อย"
        }
        guard let file = payload.files.first else {
            return "ช่วยอ่านข้อความนี้และบอกสิ่งสำคัญให้หน่อย"
        }
        switch file.pathExtension.lowercased() {
        case "pdf", "doc", "docx", "rtf", "txt", "md":
            return "ช่วยสรุปไฟล์นี้ให้หน่อย"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff":
            return "ช่วยดูภาพนี้และบอกว่ามีอะไรสำคัญ"
        case "swift", "m", "mm", "h", "js", "jsx", "ts", "tsx", "py", "rb", "go", "rs",
             "java", "kt", "c", "cc", "cpp", "cs", "php", "sh", "zsh":
            return "ช่วยตรวจไฟล์นี้และแนะนำสิ่งที่ควรปรับ"
        case "zip", "tar", "gz", "7z", "rar":
            return "ช่วยดูว่าไฟล์นี้มีอะไรและแนะนำขั้นตอนต่อไป"
        default:
            return "ช่วยดูไฟล์นี้และบอกสิ่งสำคัญให้หน่อย"
        }
    }

    func prepareCourierQuestion(_ question: String) -> NSMenu? {
        guard let payload = pendingCourierPayload else { return nil }
        let clean = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        pendingCourierPayload = payload.asking(clean)
        chatInput?.stringValue = ""
        chatWindow?.orderOut(nil)
        let menu = makeCourierTargetMenu()
        guard !courierChoices.isEmpty else {
            pendingCourierPayload = nil
            say("งาน Codex กับ Claude ปิดไปแล้ว ลากมาให้น้องใหม่ได้เลย", for: 4.0)
            transitionState(to: "sit", duration: 1.0)
            return nil
        }
        return menu
    }

    func cancelCourierQuestion() {
        guard pendingCourierPayload != nil else { return }
        pendingCourierPayload = nil
        courierChoices.removeAll()
        if focusPhase == .idle, !held {
            transitionState(to: "sit", duration: 1.0)
        }
    }

    func makeCourierTargetMenu() -> NSMenu {
        let menu = NSMenu(title: "ส่งด้วยน้องแมว")
        courierChoices.removeAll()
        for (source, title) in [("codex", "Codex"), ("claude", "Claude Code")] {
            let heading = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            heading.isEnabled = false
            menu.addItem(heading)
            let sessions = workSessions.filter { $0.source == source }.prefix(6)
            if sessions.isEmpty {
                let empty = NSMenuItem(title: "  ไม่มีงานล่าสุด", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                menu.addItem(empty)
            } else {
                for session in sessions {
                    let token = UUID().uuidString
                    courierChoices[token] = session
                    let item = NSMenuItem(title: "  " + sessionHeadline(session),
                                          action: #selector(chooseCourierTarget(_:)),
                                          keyEquivalent: "")
                    item.target = self
                    item.representedObject = token
                    menu.addItem(item)
                }
            }
            if source == "codex" { menu.addItem(.separator()) }
        }
        menu.addItem(.separator())
        let hint = NSMenuItem(title: "วางให้อัตโนมัติเมื่ออนุญาต Accessibility • ไม่กด Enter",
                              action: nil,
                              keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        return menu
    }

    @objc func chooseCourierTarget(_ sender: NSMenuItem) {
        guard let token = sender.representedObject as? String,
              let session = courierChoices[token], let payload = pendingCourierPayload else { return }
        courierChoices.removeAll()
        pendingCourierPayload = nil
        performCourierDelivery(payload, to: session)
    }

    func performCourierDelivery(_ payload: CourierPayload, to session: WorkSession) {
        shepherdTarget = nil
        activeWorkNotice = nil
        activeContextRescue = nil
        bubbleTarget = nil
        if ProcessInfo.processInfo.environment["PIXELCAT_SIMCOURIER"] == nil {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(payload.pasteboardText, forType: .string)
        }
        let finish: () -> Void = { [weak self] in
            guard let self else { return }
            self.hurry = false
            self.openTarget(session)
            let verb = payload.question.isEmpty ? "ส่ง" : "เตรียมคำถามเรื่อง"
            if self.scheduleCourierPaste(to: session) {
                self.say("\(verb) \(payload.label) ให้ \(self.workSourceName(session)) แล้ว • กำลังวางให้",
                         for: 7.0, target: session)
            } else {
                self.say("\(verb) \(payload.label) ให้ \(self.workSourceName(session)) แล้ว • วางด้วย ⌘V",
                         for: 7.0, target: session)
            }
            self.transitionState(to: "sit", duration: 2.0)
        }
        // Calm และ Reduce Motion ใช้การส่งทันที ไม่เริ่ม courier แล้วถูก tick ถัดไปยกเลิกกลางทาง
        guard effectiveMotionLevel != .calm else {
            finish()
            return
        }
        let targetMidX = taskWindowRect(session)?.midX
            ?? (session.source == "codex" ? plat.maxX : plat.minX)
        dir = targetMidX >= x + spriteW / 2 ? 1 : -1
        target = clampX(x + dir * 120)
        hurry = true
        setState("courier", duration: 99, then: finish)
    }

    /// วางอย่างเดียว ไม่กด Enter — พ่อยังเห็น prompt และเป็นคนยืนยันก่อนส่งทุกครั้ง
    /// หาก Accessibility ยังไม่พร้อมจะคง clipboard ไว้ให้ ⌘V เองเหมือนเดิม
    @discardableResult
    func scheduleCourierPaste(to session: WorkSession) -> Bool {
        courierPasteGeneration += 1
        let generation = courierPasteGeneration
        let trusted = courierPastePermissionOverride ?? AXIsProcessTrusted()
        guard trusted else {
            requestAccessibilityOnce()
            return false
        }
        if ProcessInfo.processInfo.environment["PIXELCAT_SIMCOURIER"] != nil {
            return attemptCourierPaste(to: session, generation: generation)
        }
        for (attempt, delay) in [0.9, 1.7, 2.8].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, generation == self.courierPasteGeneration else { return }
                if self.attemptCourierPaste(to: session, generation: generation) { return }
                if attempt == 2 {
                    self.say("น้องเปิดงานให้แล้ว แต่ช่องพิมพ์ยังไม่พร้อม • วางด้วย ⌘V ได้เลย",
                             for: 6.0, target: session)
                }
            }
        }
        return true
    }

    func courierTargetIsFrontmost(_ session: WorkSession) -> Bool {
        if let override = courierFrontmostOverride { return override }
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        if session.appPIDs.contains(Int(app.processIdentifier)) { return true }
        let identity = "\(app.localizedName ?? "") \(app.bundleIdentifier ?? "")".lowercased()
        if session.source == "codex" {
            return identity.contains("codex") || identity.contains("chatgpt")
        }
        return identity.contains("claude") || identity.contains("warp")
            || identity.contains("iterm") || identity.contains("terminal")
            || identity.contains("ghostty")
    }

    @discardableResult
    func attemptCourierPaste(to session: WorkSession, generation: Int) -> Bool {
        guard generation == courierPasteGeneration, courierTargetIsFrontmost(session) else {
            return false
        }
        if ProcessInfo.processInfo.environment["PIXELCAT_SIMCOURIER"] != nil {
            lastSimulatedCourierPaste = true
        } else {
            guard let source = CGEventSource(stateID: .combinedSessionState),
                  let down = CGEvent(keyboardEventSource: source,
                                     virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
                  let up = CGEvent(keyboardEventSource: source,
                                   virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
                return false
            }
            down.flags = .maskCommand
            up.flags = .maskCommand
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        courierPasteGeneration += 1             // ยกเลิก retry ที่เหลือ ป้องกันวางซ้ำ
        say("น้องวางคำถามให้แล้ว • ตรวจดูแล้วกด Enter ได้เลย", for: 7.0, target: session)
        return true
    }
}
